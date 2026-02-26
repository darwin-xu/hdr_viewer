import AVFoundation
import CoreImage
import MetalKit
import QuartzCore
import SwiftUI

// MARK: - SwiftUI Bridge

/// Metal-backed video player with EDR support.
/// Pulls frames via AVPlayerItemVideoOutput, applies the same HDR boost
/// CIFilter chain as HDRMetalView, and renders through a CAMetalLayer
/// with `wantsExtendedDynamicRangeContent` so values > 1.0 drive the
/// display above SDR white.  Toggling boost just flips a flag — no
/// player-item replacement, no blink.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    let hdrBoostEnabled: Bool
    let hdrBoostIntensity: Double

    func makeCoordinator() -> VideoPlayerCoordinator {
        VideoPlayerCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let coord = context.coordinator
        coord.hdrBoostEnabled = hdrBoostEnabled
        coord.hdrBoostIntensity = hdrBoostIntensity
        coord.loadVideo(url: url)
        return coord.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.hdrBoostEnabled = hdrBoostEnabled
        coord.hdrBoostIntensity = hdrBoostIntensity
        if coord.currentURL != url {
            coord.loadVideo(url: url)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: VideoPlayerCoordinator) {
        coordinator.cleanup()
    }
}

// MARK: - Coordinator (owns AVPlayer, Metal renderer, controls)

final class VideoPlayerCoordinator: NSObject, MTKViewDelegate {
    let containerView: VideoContainerView
    private let mtkView: MTKView

    private(set) var currentURL: URL?
    var hdrBoostEnabled = false
    var hdrBoostIntensity = 0.45

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private var lastCIImage: CIImage?
    private var videoOrientation: CGImagePropertyOrientation = .up

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    override init() {
        let device = MTLCreateSystemDefaultDevice()!

        mtkView = MTKView()
        mtkView.device = device
        mtkView.colorPixelFormat = .rgba16Float
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.wantsExtendedDynamicRangeContent = true
        }

        containerView = VideoContainerView()

        super.init()

        let edrCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        ciContext = CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: edrCS,
            .outputColorSpace: edrCS
        ])
        commandQueue = device.makeCommandQueue()

        mtkView.delegate = self
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(mtkView)
        containerView.coordinator = self
        containerView.setupControls()

        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: containerView.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    // MARK: - Video lifecycle

    func loadVideo(url: URL) {
        cleanup()
        currentURL = url
        lastCIImage = nil
        isPlaying = false

        let asset = AVAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output

        // Orientation from video track transform (for iPhone-shot portrait video)
        if let track = asset.tracks(withMediaType: .video).first {
            videoOrientation = Self.orientation(from: track.preferredTransform)
        } else {
            videoOrientation = .up
        }

        duration = CMTimeGetSeconds(asset.duration)

        let p = AVPlayer(playerItem: item)
        player = p

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.containerView.updateTime(CMTimeGetSeconds(time))
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.containerView.updatePlayState(false)
        }

        containerView.updateDuration(duration)
        containerView.updateTime(0)
        containerView.updatePlayState(false)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            // If at the end, rewind first
            if let item = player.currentItem {
                let current = CMTimeGetSeconds(item.currentTime())
                if current >= duration - 0.1 {
                    player.seek(to: .zero)
                }
            }
            player.play()
        }
        isPlaying.toggle()
        containerView.updatePlayState(isPlaying)
    }

    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cleanup() {
        if let obs = timeObserver, let player { player.removeTimeObserver(obs) }
        timeObserver = nil
        if let end = endObserver { NotificationCenter.default.removeObserver(end) }
        endObserver = nil
        player?.pause()
        player = nil
        videoOutput = nil
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let ciContext,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // Pull latest video frame
        if let output = videoOutput {
            let hostTime = CACurrentMediaTime()
            let itemTime = output.itemTime(forHostTime: hostTime)
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                if let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                    // CIImage(cvPixelBuffer:) automatically reads the correct
                    // color space from CVAttachments set by AVFoundation — no
                    // manual tagging needed.  CIContext handles conversion to
                    // the extendedLinearDisplayP3 working/output space.
                    lastCIImage = CIImage(cvPixelBuffer: pb).oriented(videoOrientation)
                }
            }
        }

        // Clear
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        encoder?.endEncoding()

        let edrCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

        if var image = lastCIImage {
            if hdrBoostEnabled {
                image = Self.applyHDRBoost(to: image, intensity: hdrBoostIntensity)
            }
            let fitted = Self.fitImage(image, into: view.drawableSize)
            ciContext.render(fitted, to: drawable.texture, commandBuffer: commandBuffer,
                            bounds: CGRect(origin: .zero, size: view.drawableSize),
                            colorSpace: edrCS)
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - HDR Boost (tuned for video)
    //
    // SDR video in linear space has virtually all pixels capped at 1.0,
    // so the photo threshold of 0.85 catches almost nothing.  We use a
    // lower threshold (0.55) to reach into mid-tones and a steeper
    // headroom ramp so the effect is perceptually similar to the photo
    // boost at the same slider position.

    private static func applyHDRBoost(to image: CIImage, intensity: Double) -> CIImage {
        let clamped = min(max(intensity, 0), 1)
        let threshold = 0.55
        let headroom = 1.8 + (clamped * 2.5)   // 1.8x – 4.3x SDR white

        let luminance = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        let midRamp = threshold + (1.0 - threshold) * 0.5
        let highlightMask = luminance.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.0, y: 0.0),
            "inputPoint1": CIVector(x: CGFloat(threshold * 0.5), y: 0.0),
            "inputPoint2": CIVector(x: CGFloat(threshold), y: 0.0),
            "inputPoint3": CIVector(x: CGFloat(midRamp), y: 0.5),
            "inputPoint4": CIVector(x: 1.0, y: 1.0)
        ])

        let ev = log2(headroom)
        let boosted = image.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: ev
        ])

        return boosted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: highlightMask
        ])
    }

    private static func fitImage(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(size.width / extent.width, size.height / extent.height)
        let tx = (size.width - extent.width * scale) * 0.5
        let ty = (size.height - extent.height * scale) * 0.5
        let transform = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: tx / scale, y: ty / scale)
        return image.transformed(by: transform)
    }

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = t.a, b = t.b, c = t.c, d = t.d
        if a == 0 && b == 1 && c == -1 && d == 0 { return .right }  // 90° CW
        if a == 0 && b == -1 && c == 1 && d == 0 { return .left }   // 90° CCW
        if a == -1 && b == 0 && c == 0 && d == -1 { return .down }  // 180°
        return .up
    }
}

// MARK: - Container View (Metal view + floating transport controls)

final class VideoContainerView: NSView {
    weak var coordinator: VideoPlayerCoordinator?

    private let controlsBar = NSVisualEffectView()
    private let playButton = NSButton()
    private let seekSlider = VideoTrackingSlider()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private var controlsTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var duration: Double = 0

    func setupControls() {
        wantsLayer = true

        // Frosted-glass controls bar
        controlsBar.material = .hudWindow
        controlsBar.blendingMode = .behindWindow
        controlsBar.state = .active
        controlsBar.wantsLayer = true
        controlsBar.layer?.cornerRadius = 8
        controlsBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsBar)

        // Play / Pause
        playButton.bezelStyle = .regularSquare
        playButton.isBordered = false
        playButton.image = NSImage(systemSymbolName: "play.fill",
                                   accessibilityDescription: "Play")
        playButton.contentTintColor = .white
        playButton.target = self
        playButton.action = #selector(playPauseTapped)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        controlsBar.addSubview(playButton)

        // Seek slider
        seekSlider.minValue = 0
        seekSlider.maxValue = 1
        seekSlider.doubleValue = 0
        seekSlider.isContinuous = true
        seekSlider.target = self
        seekSlider.action = #selector(sliderChanged)
        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        controlsBar.addSubview(seekSlider)

        // Time label
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        controlsBar.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            controlsBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            controlsBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            controlsBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            controlsBar.heightAnchor.constraint(equalToConstant: 44),

            playButton.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 12),
            playButton.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 24),
            playButton.heightAnchor.constraint(equalToConstant: 24),

            seekSlider.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            seekSlider.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: seekSlider.trailingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
        ])

        controlsBar.alphaValue = 1  // start visible (paused)
    }

    // MARK: - Public state updates

    func updatePlayState(_ playing: Bool) {
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play"
        )
        if playing { scheduleHide(after: 3) } else { showControls() }
    }

    func updateTime(_ seconds: Double) {
        guard !seekSlider.isTracking else { return }  // don't fight the user's drag
        if duration > 0 { seekSlider.doubleValue = seconds / duration }
        timeLabel.stringValue = "\(Self.fmt(seconds)) / \(Self.fmt(duration))"
    }

    func updateDuration(_ dur: Double) { duration = dur }

    // MARK: - Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        trackingArea = ta
        addTrackingArea(ta)
    }

    override func mouseEntered(with event: NSEvent) { showControls() }
    override func mouseMoved(with event: NSEvent)   { showControls() }
    override func mouseExited(with event: NSEvent)   { scheduleHide(after: 1) }

    // MARK: - Actions

    @objc private func playPauseTapped() { coordinator?.togglePlayPause() }

    @objc private func sliderChanged() { coordinator?.seek(to: seekSlider.doubleValue) }

    // MARK: - Show / hide

    private func showControls() {
        controlsTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            controlsBar.animator().alphaValue = 1
        }
        if coordinator?.isPlaying == true { scheduleHide(after: 3) }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        controlsTimer?.invalidate()
        guard coordinator?.isPlaying == true else { return }
        controlsTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.controlsBar.animator().alphaValue = 0
            }
        }
    }

    private static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Slider subclass that exposes drag state

final class VideoTrackingSlider: NSSlider {
    private(set) var isTracking = false
    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event)   // blocks until mouse-up
        isTracking = false
    }
}

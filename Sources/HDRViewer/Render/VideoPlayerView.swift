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
    /// Authoritative duration from ffprobe (seconds). When set, this
    /// overrides whatever AVPlayer reports (which can be wrong for
    /// progressive / fragmented MP4).
    var knownDuration: Double?
    /// Video projection type — determines rendering mode.
    var projection: VideoProjection = .flat

    func makeCoordinator() -> VideoPlayerCoordinator {
        VideoPlayerCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let coord = context.coordinator
        coord.hdrBoostEnabled = hdrBoostEnabled
        coord.hdrBoostIntensity = hdrBoostIntensity
        coord.knownDuration = knownDuration
        coord.projection = projection
        coord.loadVideo(url: url)
        return coord.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.hdrBoostEnabled = hdrBoostEnabled
        coord.hdrBoostIntensity = hdrBoostIntensity
        coord.knownDuration = knownDuration
        coord.projection = projection
        if coord.currentURL != url {
            coord.loadVideo(url: url)
        }
        // If known duration arrives after loadVideo (e.g. ffprobe completes
        // while progressive playback already started), push it to the UI.
        if let kd = knownDuration, kd > 0, abs(coord.duration - kd) > 0.5 {
            coord.setAuthoritativeDuration(kd)
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
    /// Authoritative duration from ffprobe. When set, takes priority
    /// over whatever AVPlayer reports.
    var knownDuration: Double?
    /// Video projection type — determines rendering mode
    /// (flat, equirectangular, or dual-fisheye).
    var projection: VideoProjection = .flat

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private var lastCIImage: CIImage?
    private var videoOrientation: CGImagePropertyOrientation = .up

    // --- 360° panorama state ---
    private var panoramaRenderer: PanoramaRenderer?
    private var equirectTexture: MTLTexture?
    /// In-memory dual-fisheye reader (replaces ffmpeg transcode for .insv).
    private var dualFisheyeReader: DualFisheyeReader?
    /// Camera yaw in radians (positive = look right).
    var panoYaw: Float = 0
    /// Camera pitch in radians (positive = look up), clamped ±π/2.
    var panoPitch: Float = 0
    /// Vertical field-of-view in degrees.
    var panoFOV: Float = 90

    // --- Frame-skip state ---
    private var cachedBoostEnabled = false
    private var cachedBoostIntensity = 0.45
    private var lastDrawableSize: CGSize = .zero
    private var hasRenderedContent = false        // at least one frame rendered

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationObserver: NSKeyValueObservation?
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private var wasPlayingBeforeSeek = false

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
        hasRenderedContent = false

        // For .insv files, AVFoundation needs a symlink with .mp4 extension
        // (the container is MP4 but the UTI is unrecognized).
        let avURL = DualFisheyeReader.avFoundationURL(for: url)
        let asset = AVAsset(url: avURL)
        let videoTracks = asset.tracks(withMediaType: .video)

        // ── Dual-stream .insv: in-memory decode (no temp file) ──────
        let ext = url.pathExtension.lowercased()
        if ext == "insv" && videoTracks.count >= 2 {
            do {
                let reader = try DualFisheyeReader(url: url)
                dualFisheyeReader = reader

                if let kd = knownDuration, kd > 0 {
                    duration = kd
                } else {
                    let avDur = CMTimeGetSeconds(asset.duration)
                    duration = (avDur.isFinite && avDur > 0) ? avDur : 0
                }

                // Audio-only AVPlayer (video tracks disabled to save resources)
                let item = AVPlayerItem(asset: asset)
                for track in item.tracks {
                    if track.assetTrack?.mediaType == .video {
                        track.isEnabled = false
                    }
                }
                let p = AVPlayer(playerItem: item)
                player = p

                setupPlayerObservers(player: p, item: item)
                reader.startDecoding()

                containerView.updateDuration(duration)
                containerView.updateTime(0)
                containerView.updatePlayState(false)
                return
            } catch {
                NSLog("[VideoPlayer] DualFisheyeReader failed: \(error); using standard path")
                dualFisheyeReader = nil
            }
        }

        // ── Standard AVPlayer path ──────────────────────────────────
        let item = AVPlayerItem(asset: asset)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output

        // Orientation from video track transform (for iPhone-shot portrait video)
        if let track = videoTracks.first {
            videoOrientation = Self.orientation(from: track.preferredTransform)
        } else {
            videoOrientation = .up
        }

        if let kd = knownDuration, kd > 0 {
            duration = kd
        } else {
            let avDur = CMTimeGetSeconds(asset.duration)
            duration = (avDur.isFinite && avDur > 0) ? avDur : 0
        }

        let p = AVPlayer(playerItem: item)
        player = p

        setupPlayerObservers(player: p, item: item)

        containerView.updateDuration(duration)
        containerView.updateTime(0)
        containerView.updatePlayState(false)
    }

    /// Set up time / end-of-playback / duration observers on the player.
    /// Shared by both the dual-fisheye and standard playback paths.
    private func setupPlayerObservers(player p: AVPlayer, item: AVPlayerItem) {
        // KVO: update duration when AVPlayer resolves it (fragmented MP4
        // with empty_moov starts with unknown duration; AVPlayer fills it
        // in as it reads more fragments). Skip if we already have an
        // authoritative duration from ffprobe.
        durationObserver = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let kd = self.knownDuration, kd > 0 { return }
                let d = CMTimeGetSeconds(item.duration)
                if d.isFinite && d > 0 && d != self.duration {
                    self.duration = d
                    self.containerView.updateDuration(d)
                }
            }
        }

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
    }

    /// Update duration from an authoritative source (ffprobe).
    func setAuthoritativeDuration(_ dur: Double) {
        guard dur > 0 else { return }
        knownDuration = dur
        duration = dur
        containerView.updateDuration(dur)
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
                    dualFisheyeReader?.seek(to: .zero)
                }
            }
            player.play()
        }
        isPlaying.toggle()
        containerView.updatePlayState(isPlaying)
    }

    /// Seek with fast (non-exact) tolerance — suitable for continuous
    /// dragging where responsiveness matters more than frame accuracy.
    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
    }

    /// Exact seek — used on drag end for frame-accurate final position.
    func seekExact(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        dualFisheyeReader?.seek(to: target)
    }

    /// Pause playback temporarily for seeking; remembers the playing state.
    func beginSeeking() {
        wasPlayingBeforeSeek = isPlaying
        if isPlaying { player?.pause() }
    }

    /// Resume playback if it was playing before the seek began, and
    /// do a final frame-accurate seek.
    func endSeeking(at fraction: Double) {
        seekExact(to: fraction)
        if wasPlayingBeforeSeek {
            player?.play()
            isPlaying = true
            containerView.updatePlayState(true)
        }
    }

    func cleanup() {
        if let obs = timeObserver, let player { player.removeTimeObserver(obs) }
        timeObserver = nil
        if let end = endObserver { NotificationCenter.default.removeObserver(end) }
        endObserver = nil
        durationObserver?.invalidate()
        durationObserver = nil
        player?.pause()
        player = nil
        videoOutput = nil
        dualFisheyeReader?.cancel()
        dualFisheyeReader = nil
        hasRenderedContent = false
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ciContext, let commandQueue else { return }
        let device = view.device!

        // ── 1. Pull latest video frame ──────────────────────────────
        var gotNewFrame = false
        if let reader = dualFisheyeReader, let p = player {
            // Dual-fisheye: composited frame from in-memory reader
            let currentTime = p.currentTime()
            if let composite = reader.compositeFrame(at: currentTime) {
                lastCIImage = composite
                gotNewFrame = true
            }
        } else if let output = videoOutput {
            let hostTime = CACurrentMediaTime()
            let itemTime = output.itemTime(forHostTime: hostTime)
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                lastCIImage = CIImage(cvPixelBuffer: pb).oriented(videoOrientation)
                gotNewFrame = true
            }
        }

        // ── 2. Detect whether re-render is needed ───────────────────
        let boostChanged = hdrBoostEnabled != cachedBoostEnabled
                        || abs(hdrBoostIntensity - cachedBoostIntensity) > 0.001
        let sizeChanged  = view.drawableSize != lastDrawableSize
        // In 360° mode we always re-render because the user may be
        // dragging the view (camera yaw/pitch change every frame).
        let needsRender  = gotNewFrame || boostChanged || sizeChanged || !hasRenderedContent || projection.is360

        if !needsRender { return }

        cachedBoostEnabled   = hdrBoostEnabled
        cachedBoostIntensity = hdrBoostIntensity
        lastDrawableSize     = view.drawableSize

        // ── 3. Render ───────────────────────────────────────────────
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        if projection.is360, var image = lastCIImage {
            // ── 360° panorama: two-pass rendering ───────────────────
            // Pass 1: Render CIImage (+ HDR boost) to offscreen texture
            if hdrBoostEnabled {
                image = Self.applyHDRBoost(to: image, intensity: hdrBoostIntensity)
            }

            let extent = image.extent
            let texW = Int(extent.width)
            let texH = Int(extent.height)

            // Lazily create / resize offscreen equirectangular texture
            if panoramaRenderer == nil {
                do {
                    panoramaRenderer = try PanoramaRenderer(device: device, pixelFormat: view.colorPixelFormat)
                } catch {
                    NSLog("PanoramaRenderer init failed: \(error)")
                }
            }
            guard let panoRenderer = panoramaRenderer else {
                commandBuffer.commit()
                return
            }
            equirectTexture = panoRenderer.offscreenTexture(
                width: texW, height: texH, existing: equirectTexture
            )
            guard let offscreen = equirectTexture else {
                commandBuffer.commit()
                return
            }

            let edrCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            ciContext.render(
                image, to: offscreen, commandBuffer: commandBuffer,
                bounds: image.extent,
                colorSpace: edrCS
            )

            // Pass 2: Perspective projection from equirectangular texture
            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = drawable.texture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
                let panoMode: PanoProjectionMode = projection == .dualFisheye ? .dualFisheye : .equirectangular
                panoRenderer.draw(
                    encoder: encoder,
                    texture: offscreen,
                    yaw: panoYaw,
                    pitch: panoPitch,
                    fov: panoFOV,
                    drawableSize: view.drawableSize,
                    mode: panoMode
                )
                encoder.endEncoding()
            }
        } else if var image = lastCIImage {
            // ── Flat video: single-pass CIContext render ────────────
            // Clear to black
            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = drawable.texture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
            encoder?.endEncoding()

            if hdrBoostEnabled {
                image = Self.applyHDRBoost(to: image, intensity: hdrBoostIntensity)
            }
            let fitted = Self.fitImage(image, into: view.drawableSize)
            let edrCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            ciContext.render(fitted, to: drawable.texture, commandBuffer: commandBuffer,
                            bounds: CGRect(origin: .zero, size: view.drawableSize),
                            colorSpace: edrCS)
        } else {
            // No image yet — clear to black
            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = drawable.texture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
            encoder?.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        hasRenderedContent = true
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

    /// Whether 360° panorama drag interaction is active.
    private var isPanoDragging = false
    /// Last mouse position during a panorama drag.
    private var lastPanoDragPoint: NSPoint = .zero

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
        seekSlider.containerView = self
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

    // MARK: - 360° panorama mouse interaction

    override func mouseDown(with event: NSEvent) {
        // If in 360° mode and the click is NOT on the controls bar, start drag
        if coordinator?.projection.is360 == true {
            let loc = convert(event.locationInWindow, from: nil)
            if !controlsBar.frame.contains(loc) {
                isPanoDragging = true
                lastPanoDragPoint = loc
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanoDragging, let coord = coordinator {
            let loc = convert(event.locationInWindow, from: nil)
            let dx = Float(loc.x - lastPanoDragPoint.x)
            let dy = Float(loc.y - lastPanoDragPoint.y)
            lastPanoDragPoint = loc

            // Sensitivity: ~0.3° per pixel
            let sensitivity: Float = 0.005  // radians per pixel
            coord.panoYaw -= dx * sensitivity
            coord.panoPitch += dy * sensitivity
            // Clamp pitch to ±π/2
            coord.panoPitch = min(.pi / 2, max(-.pi / 2, coord.panoPitch))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isPanoDragging {
            isPanoDragging = false
            return
        }
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // In 360° mode, scroll wheel adjusts FOV (zoom)
        if coordinator?.projection.is360 == true {
            let delta = Float(event.scrollingDeltaY) * 0.5  // degrees per scroll unit
            coordinator?.panoFOV -= delta
            coordinator?.panoFOV = min(180, max(20, coordinator?.panoFOV ?? 100))
            return
        }
        super.scrollWheel(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Actions

    @objc private func playPauseTapped() { coordinator?.togglePlayPause() }

    @objc private func sliderChanged() {
        coordinator?.seek(to: seekSlider.doubleValue)
    }

    /// Called when the user first clicks on the slider.
    func sliderBeganTracking() {
        coordinator?.beginSeeking()
    }

    /// Called when the user releases the slider.
    func sliderEndedTracking() {
        coordinator?.endSeeking(at: seekSlider.doubleValue)
    }

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
    weak var containerView: VideoContainerView?

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        containerView?.sliderBeganTracking()
        super.mouseDown(with: event)   // blocks until mouse-up
        isTracking = false
        containerView?.sliderEndedTracking()
    }
}

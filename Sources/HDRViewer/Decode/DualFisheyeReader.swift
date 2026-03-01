import AVFoundation
import CoreImage
import Foundation

/// Reads both video tracks from a dual-stream .insv file using AVAssetReader
/// and composites them into a single side-by-side CIImage for the panorama
/// renderer.  This eliminates the ffmpeg transcode + temp-file step.
///
/// The composited CIImage is consumed by the existing rendering pipeline:
///   HDR boost → CIContext.render → offscreen MTLTexture → PanoramaRenderer
///
/// Thread model:
///   - `compositeFrame(at:)` is called from the render thread (MTKViewDelegate)
///   - Background decoding runs on a dedicated serial DispatchQueue
///   - An NSLock protects the shared frame buffer
final class DualFisheyeReader {

    // MARK: - AVFoundation .insv workaround

    /// AVFoundation refuses to open `.insv` files because the extension has
    /// no registered UTI.  The container *is* standard MP4, so a symlink
    /// with a `.mp4` extension lets AVFoundation read it without copying
    /// any data.  The symlinks live in a temp folder and are cheap to
    /// recreate across sessions.
    static func avFoundationURL(for url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        guard ext == "insv" else { return url }

        let linkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HDRViewer_insv_links", isDirectory: true)
        try? FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)

        let linkURL = linkDir.appendingPathComponent(url.lastPathComponent + ".mp4")
        // Remove stale link and (re)create.  Errors are non-fatal —
        // worst case AVFoundation fails and we log the issue.
        try? FileManager.default.removeItem(at: linkURL)
        try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: url)
        return linkURL
    }

    // MARK: - Types

    /// A decoded frame pair (one per fisheye lens).
    private struct FramePair {
        let front: CVPixelBuffer
        let rear: CVPixelBuffer
        let pts: CMTime
    }

    enum ReaderError: LocalizedError {
        case insufficientVideoTracks
        case cannotCreateReader(Error)
        case cannotStartReader(Error?)

        var errorDescription: String? {
            switch self {
            case .insufficientVideoTracks:
                return "Expected at least 2 video tracks in .insv file"
            case .cannotCreateReader(let e):
                return "AVAssetReader creation failed: \(e.localizedDescription)"
            case .cannotStartReader(let e):
                return "AVAssetReader start failed: \(e?.localizedDescription ?? "unknown")"
            }
        }
    }

    // MARK: - Properties

    private let asset: AVAsset
    private let frontTrack: AVAssetTrack
    private let rearTrack: AVAssetTrack
    let duration: CMTime

    private var reader: AVAssetReader?
    private var frontOutput: AVAssetReaderTrackOutput?
    private var rearOutput: AVAssetReaderTrackOutput?

    /// Ring buffer of decoded frame pairs, sorted by PTS ascending.
    private var buffer: [FramePair] = []
    private let bufferCapacity = 5
    private let lock = NSLock()

    /// Cached composite CIImage from the last consumed frame pair.
    /// Returned when the buffer is empty (paused, between seeks, etc.).
    private var lastComposite: CIImage?

    /// Serial queue for background decoding.
    private let decodeQueue = DispatchQueue(
        label: "com.hdrviewer.dualfisheye",
        qos: .userInitiated
    )

    /// Monotonically increasing generation counter.
    /// Incremented on every start / seek / cancel.  Decode loops exit
    /// when their captured generation no longer matches.
    private var generation: UInt64 = 0

    /// Output pixel buffer attributes — matches VideoPlayerView's format
    /// (64-bit RGBA half-float, Metal-compatible).
    private static let pixelBufferAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private let log = Logger.shared

    // MARK: - Initialisation

    /// Create a reader for the given dual-stream .insv URL.
    /// Throws if the file has fewer than 2 video tracks.
    init(url: URL) throws {
        let avURL = Self.avFoundationURL(for: url)
        asset = AVAsset(url: avURL)
        let tracks = asset.tracks(withMediaType: .video)
        guard tracks.count >= 2 else {
            throw ReaderError.insufficientVideoTracks
        }
        frontTrack = tracks[0]
        rearTrack = tracks[1]
        duration = asset.duration

        log.info(
            "DualFisheyeReader: \(url.lastPathComponent), "
            + "\(Int(frontTrack.naturalSize.width))×\(Int(frontTrack.naturalSize.height)) per lens, "
            + "\(tracks.count) tracks",
            source: "DualFisheye"
        )

        try createReader(from: .zero)
    }

    // MARK: - Public API

    /// Begin background decoding from the current reader position.
    func startDecoding() {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()

        decodeQueue.async { [self] in
            decodeLoop(generation: gen)
        }
    }

    /// Stop decoding and release resources.
    func cancel() {
        lock.lock()
        generation += 1
        buffer.removeAll()
        lastComposite = nil
        lock.unlock()

        reader?.cancelReading()
        reader = nil
    }

    /// Seek to a new playback time.  Flushes the buffer, recreates the
    /// AVAssetReader at the target time, and restarts decoding.
    func seek(to time: CMTime) {
        lock.lock()
        generation += 1
        let gen = generation
        buffer.removeAll()
        lastComposite = nil
        lock.unlock()

        reader?.cancelReading()

        decodeQueue.async { [self] in
            // Bail if a newer seek / cancel already superseded us.
            lock.lock()
            let current = generation
            lock.unlock()
            guard current == gen else { return }

            do {
                try createReader(from: time)
                decodeLoop(generation: gen)
            } catch {
                log.error("DualFisheyeReader seek failed: \(error)", source: "DualFisheye")
            }
        }
    }

    /// Return a composited side-by-side CIImage for the given playback
    /// time.  Called from the render thread at up to 60 fps.
    ///
    /// Returns `nil` only if no frame has been decoded yet.
    func compositeFrame(at time: CMTime) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else {
            return lastComposite
        }

        // If all buffered frames are ahead of the requested time
        // (e.g. right after a backward seek, before decode catches up),
        // return the cached composite.
        if CMTimeCompare(buffer[0].pts, time) > 0 {
            return lastComposite
        }

        // Find the latest frame whose PTS ≤ requested time.
        var bestIdx = 0
        for i in 1..<buffer.count {
            if CMTimeCompare(buffer[i].pts, time) <= 0 {
                bestIdx = i
            } else {
                break
            }
        }

        let pair = buffer[bestIdx]
        // Drop consumed frames (including earlier ones we skipped).
        buffer.removeFirst(bestIdx + 1)

        let composite = Self.composite(front: pair.front, rear: pair.rear)
        lastComposite = composite
        return composite
    }

    // MARK: - Private

    /// Create (or replace) the AVAssetReader starting at the given time.
    private func createReader(from time: CMTime) throws {
        reader?.cancelReading()

        let r: AVAssetReader
        do {
            r = try AVAssetReader(asset: asset)
        } catch {
            throw ReaderError.cannotCreateReader(error)
        }

        r.timeRange = CMTimeRange(start: time, end: duration)

        let fOut = AVAssetReaderTrackOutput(
            track: frontTrack,
            outputSettings: Self.pixelBufferAttrs
        )
        let rOut = AVAssetReaderTrackOutput(
            track: rearTrack,
            outputSettings: Self.pixelBufferAttrs
        )
        fOut.alwaysCopiesSampleData = false
        rOut.alwaysCopiesSampleData = false

        guard r.canAdd(fOut), r.canAdd(rOut) else {
            throw ReaderError.cannotStartReader(nil)
        }
        r.add(fOut)
        r.add(rOut)

        guard r.startReading() else {
            throw ReaderError.cannotStartReader(r.error)
        }

        reader = r
        frontOutput = fOut
        rearOutput = rOut
    }

    /// Background decode loop.  Runs until EOF, error, or generation
    /// mismatch (which means a seek or cancel superseded us).
    private func decodeLoop(generation gen: UInt64) {
        while true {
            // Check if a newer operation supersedes this loop.
            lock.lock()
            let stale = generation != gen
            let count = buffer.count
            lock.unlock()
            if stale { return }

            // Throttle when the buffer is full so we don't spin.
            if count >= bufferCapacity {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            guard let fOut = frontOutput, let rOut = rearOutput else { return }

            // Read one sample from each track.
            guard let fSample = fOut.copyNextSampleBuffer(),
                  let rSample = rOut.copyNextSampleBuffer()
            else { return }   // EOF or reader cancelled

            guard let fPB = CMSampleBufferGetImageBuffer(fSample),
                  let rPB = CMSampleBufferGetImageBuffer(rSample)
            else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(fSample)

            lock.lock()
            if generation != gen { lock.unlock(); return }
            buffer.append(FramePair(front: fPB, rear: rPB, pts: pts))
            lock.unlock()
        }
    }

    /// Composite two fisheye CVPixelBuffers into a single side-by-side
    /// CIImage.  The result has 2:1 aspect (front | rear), matching what
    /// the dual-fisheye panorama shader expects.
    private static func composite(front: CVPixelBuffer, rear: CVPixelBuffer) -> CIImage {
        let frontImage = CIImage(cvPixelBuffer: front)
        let rearImage = CIImage(cvPixelBuffer: rear)
        let frontW = frontImage.extent.width
        let translatedRear = rearImage.transformed(
            by: CGAffineTransform(translationX: frontW, y: 0)
        )
        return translatedRear.composited(over: frontImage)
    }
}

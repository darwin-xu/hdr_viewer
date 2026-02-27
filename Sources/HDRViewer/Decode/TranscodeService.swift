import Foundation

/// Transcodes video formats that AVFoundation cannot handle natively
/// (e.g. FLV, WMV) to a temporary MP4 using ffmpeg.
///
/// Strategy: try a fast stream-copy (remux) first — this takes seconds
/// for FLV files that already contain H.264+AAC.  If the remux fails
/// (e.g. WMV with VC-1), fall back to ultrafast H.264 re-encode.
///
/// Transcoding is cancellable: call `cancelCurrent()` or let the
/// Swift concurrency task check `Task.isCancelled` — the running
/// ffmpeg process will be terminated immediately.
final class TranscodeService {
    static let shared = TranscodeService()

    private let log = Logger.shared
    private let tempDir: URL
    /// Maps original file URL → transcoded MP4 URL.
    private var cache: [URL: URL] = [:]
    private let lock = NSLock()

    /// Currently running ffmpeg process (for cancellation).
    private var activeProcess: Process?
    private let processLock = NSLock()

    private init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HDRViewer_transcode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    /// Whether the given file extension requires transcoding.
    static func needsTranscode(_ url: URL) -> Bool {
        PhotoItem.transcodeRequiredExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns the URL of a playable MP4.  Cancellation-aware: if the
    /// current Swift Task is cancelled, the ffmpeg process is killed
    /// and `CancellationError` is thrown.
    ///
    /// Designed to be called from a background thread / Task.detached.
    func playableURL(for url: URL) throws -> URL {
        guard Self.needsTranscode(url) else { return url }

        lock.lock()
        if let cached = cache[url] {
            lock.unlock()
            if FileManager.default.fileExists(atPath: cached.path) {
                log.debug("Transcode cache hit: \(url.lastPathComponent)", source: "Transcode")
                return cached
            }
        } else {
            lock.unlock()
        }

        return try transcode(url)
    }

    /// Kill any in-progress ffmpeg process.
    func cancelCurrent() {
        processLock.lock()
        let proc = activeProcess
        processLock.unlock()
        if let proc, proc.isRunning {
            log.info("Cancelling active transcode", source: "Transcode")
            proc.terminate()
        }
    }

    /// Locate ffmpeg – check common Homebrew paths, then $PATH.
    private func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["ffmpeg"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0,
           let data = try? pipe.fileHandleForReading.readToEnd(),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return nil
    }

    // MARK: - Transcode pipeline

    private func transcode(_ url: URL) throws -> URL {
        guard let ffmpegPath = findFFmpeg() else {
            log.error("ffmpeg not found — cannot transcode \(url.lastPathComponent)", source: "Transcode")
            throw TranscodeError.ffmpegNotFound
        }

        let hash = url.path.data(using: .utf8)!.map { String(format: "%02x", $0) }.suffix(16).joined()
        let baseName = url.deletingPathExtension().lastPathComponent
        let outURL = tempDir.appendingPathComponent("\(baseName)_\(hash).mp4")

        if FileManager.default.fileExists(atPath: outURL.path) {
            log.debug("Transcode output already on disk: \(outURL.lastPathComponent)", source: "Transcode")
            lock.lock()
            cache[url] = outURL
            lock.unlock()
            return outURL
        }

        // --- Step 1: Try stream-copy (remux). Instant for H.264 FLV. ---
        log.info("Trying remux (stream copy) for \(url.lastPathComponent)", source: "Transcode")
        let remuxOK = try runFFmpeg(
            path: ffmpegPath,
            arguments: [
                "-y", "-i", url.path,
                "-c", "copy",            // no re-encode
                "-movflags", "+faststart",
                "-loglevel", "warning",
                outURL.path
            ]
        )

        if remuxOK {
            log.info("Remux succeeded for \(url.lastPathComponent)", source: "Transcode")
            lock.lock()
            cache[url] = outURL
            lock.unlock()
            return outURL
        }

        // Clean up failed remux output
        try? FileManager.default.removeItem(at: outURL)

        // --- Step 2: Fall back to ultrafast re-encode ---
        log.info("Remux failed, re-encoding (ultrafast) \(url.lastPathComponent)", source: "Transcode")
        let encodeOK = try runFFmpeg(
            path: ffmpegPath,
            arguments: [
                "-y", "-i", url.path,
                "-c:v", "libx264",
                "-preset", "ultrafast",   // fastest possible encode
                "-crf", "23",             // reasonable quality
                "-c:a", "aac",
                "-b:a", "128k",
                "-movflags", "+faststart",
                "-loglevel", "warning",
                outURL.path
            ]
        )

        guard encodeOK else {
            throw TranscodeError.ffmpegFailed(exitCode: -1, message: "Both remux and re-encode failed")
        }

        log.info("Re-encode complete: \(outURL.lastPathComponent)", source: "Transcode")
        lock.lock()
        cache[url] = outURL
        lock.unlock()
        return outURL
    }

    /// Runs ffmpeg with cancellation support.
    /// Returns `true` on success, `false` on ffmpeg error.
    /// Throws `CancellationError` if the task was cancelled.
    @discardableResult
    private func runFFmpeg(path: String, arguments: [String]) throws -> Bool {
        // Check cancellation before starting
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        processLock.lock()
        activeProcess = process
        processLock.unlock()

        try process.run()

        // Poll for completion so we can react to task cancellation.
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                processLock.lock()
                activeProcess = nil
                processLock.unlock()
                // Clean up partial output
                if let outPath = arguments.last {
                    try? FileManager.default.removeItem(atPath: outPath)
                }
                log.info("Transcode cancelled by user", source: "Transcode")
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.05)  // 50ms poll
        }

        processLock.lock()
        activeProcess = nil
        processLock.unlock()

        return process.terminationStatus == 0
    }

    /// Remove all temp files.
    func cleanUp() {
        cancelCurrent()
        lock.lock()
        cache.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
}

enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case ffmpegFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg is not installed. Please install it via: brew install ffmpeg"
        case .ffmpegFailed(let code, let msg):
            return "ffmpeg exited with code \(code): \(msg)"
        }
    }
}

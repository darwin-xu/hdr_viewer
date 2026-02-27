import Foundation

/// Transcodes video formats that AVFoundation cannot handle natively
/// (e.g. FLV, WMV) to a temporary MP4 using ffmpeg.
///
/// **Speed strategy** (ordered by preference):
///   1. Stream-copy (remux) — instant for FLV with H.264
///   2. Hardware encode via VideoToolbox (`h264_videotoolbox`) — near real-time
///   3. Software `libx264 -preset ultrafast` — fallback if HW unavailable
///
/// **Progressive playback**: when re-encoding, the output uses
/// fragmented MP4 (`-movflags frag_keyframe+empty_moov`) so AVPlayer
/// can start playing after the first few seconds are written, while
/// ffmpeg continues encoding in the background.
///
/// Transcoding is cancellable: the running ffmpeg process is terminated
/// immediately when the user selects another file.
final class TranscodeService {
    static let shared = TranscodeService()

    private let log = Logger.shared
    private let tempDir: URL
    /// Maps original file URL → transcoded MP4 URL.
    private var cache: [URL: URL] = [:]
    private let lock = NSLock()

    /// Currently running ffmpeg process (for cancellation).
    /// Keyed by a UUID operation token to avoid races between
    /// overlapping detached tasks.
    private var activeProcess: Process?
    private var activeOperationID: UUID?
    private let processLock = NSLock()

    /// Whether a background transcode is still in progress for the
    /// file that is currently being played progressively.
    private(set) var isBackgroundTranscoding = false

    /// Extensions where stream-copy (remux) into MP4 is known
    /// to be impossible because the codecs are not MP4-compatible.
    /// These go directly to re-encode, skipping the pointless
    /// (and potentially slow on network volumes) remux attempt.
    private static let remuxSkipExtensions: Set<String> = [
        "wmv", "flv"   // WMV3/WMV2 and VP6/Sorenson can't go in MP4
    ]

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

    // MARK: - Public API

    /// Try a fast remux first.  Returns the playable URL immediately if
    /// remux succeeds (or cached), otherwise returns `nil` — caller
    /// should then call `transcodeProgressively`.
    func tryFastPath(for url: URL) throws -> URL? {
        guard Self.needsTranscode(url) else { return url }

        // Check cache
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

        guard let ffmpegPath = findFFmpeg() else {
            throw TranscodeError.ffmpegNotFound
        }

        let outURL = outputURL(for: url)

        if FileManager.default.fileExists(atPath: outURL.path) {
            lock.lock()
            cache[url] = outURL
            lock.unlock()
            return outURL
        }

        // Try stream-copy (remux) — instant for H.264 FLV
        // Skip remux for formats where stream-copy is known to fail
        // (e.g. WMV3/WMV2 → MP4 is impossible). This avoids a slow
        // read over the network just to get a guaranteed failure.
        let ext = url.pathExtension.lowercased()
        if Self.remuxSkipExtensions.contains(ext) {
            log.info("Skipping remux for .\(ext) (codecs not MP4-compatible), needs re-encode", source: "Transcode")
            return nil
        }

        log.info("Trying remux (stream copy) for \(url.lastPathComponent)", source: "Transcode")
        let remuxOK = try runFFmpeg(
            path: ffmpegPath,
            arguments: [
                "-nostdin", "-y", "-i", url.path,
                "-c", "copy",
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

        // Remux failed — caller should use progressive transcode
        log.info("Remux failed for \(url.lastPathComponent), needs re-encode", source: "Transcode")
        try? FileManager.default.removeItem(at: outURL)
        return nil
    }

    /// Start a background re-encode that produces a fragmented MP4.
    /// Returns the output URL immediately — the file will be written
    /// progressively and AVPlayer can start playing once the first
    /// fragments appear.
    ///
    /// Call from a detached Task; the method blocks until ffmpeg exits
    /// (or is cancelled).  Check `Task.isCancelled` periodically.
    func transcodeProgressively(for url: URL) throws -> URL {
        guard let ffmpegPath = findFFmpeg() else {
            throw TranscodeError.ffmpegNotFound
        }

        let outURL = outputURL(for: url)
        try? FileManager.default.removeItem(at: outURL)

        // Try hardware encoder first, fall back to software
        let encoderArgs = hasVideoToolbox(ffmpegPath: ffmpegPath)
            ? ["-c:v", "h264_videotoolbox", "-q:v", "65"]     // HW: quality 65 ≈ high quality
            : ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"]  // SW fallback

        log.info("Re-encoding \(url.lastPathComponent) (\(encoderArgs[1]))", source: "Transcode")

        let args: [String] = [
            "-nostdin", "-y", "-i", url.path
        ] + encoderArgs + [
            "-c:a", "aac", "-b:a", "128k",
            // Fragmented MP4: playable immediately, no moov at end
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-loglevel", "warning",
            outURL.path
        ]

        isBackgroundTranscoding = true
        defer { isBackgroundTranscoding = false }

        let ok = try runFFmpeg(path: ffmpegPath, arguments: args)

        guard ok else {
            try? FileManager.default.removeItem(at: outURL)
            throw TranscodeError.ffmpegFailed(exitCode: -1, message: "Re-encode failed")
        }

        log.info("Re-encode complete: \(outURL.lastPathComponent)", source: "Transcode")
        lock.lock()
        cache[url] = outURL
        lock.unlock()
        return outURL
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

    /// Remove all temp files.
    func cleanUp() {
        cancelCurrent()
        lock.lock()
        cache.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    func outputURL(for url: URL) -> URL {
        let hash = url.path.data(using: .utf8)!.map { String(format: "%02x", $0) }.suffix(16).joined()
        let baseName = url.deletingPathExtension().lastPathComponent
        return tempDir.appendingPathComponent("\(baseName)_\(hash).mp4")
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
        which.standardInput = FileHandle.nullDevice
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

    /// Check whether h264_videotoolbox is available.
    private func hasVideoToolbox(ffmpegPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-nostdin", "-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else { return false }
        return output.contains("h264_videotoolbox")
    }

    /// Runs ffmpeg with cancellation support and stderr capture.
    /// Returns `true` on success, `false` on ffmpeg error.
    /// Throws `CancellationError` if the task was cancelled.
    @discardableResult
    private func runFFmpeg(path: String, arguments: [String]) throws -> Bool {
        try Task.checkCancellation()

        let operationID = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        // Capture stderr for diagnostic logging
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        processLock.lock()
        activeProcess = process
        activeOperationID = operationID
        processLock.unlock()

        try process.run()
        log.debug("ffmpeg pid=\(process.processIdentifier) started: \(arguments.dropFirst().prefix(4).joined(separator: " "))…", source: "Transcode")

        // Poll for completion so we can react to task cancellation.
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                processLock.lock()
                if activeOperationID == operationID {
                    activeProcess = nil
                    activeOperationID = nil
                }
                processLock.unlock()
                if let outPath = arguments.last {
                    try? FileManager.default.removeItem(atPath: outPath)
                }
                log.info("Transcode cancelled by user", source: "Transcode")
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        processLock.lock()
        if activeOperationID == operationID {
            activeProcess = nil
            activeOperationID = nil
        }
        processLock.unlock()

        // Log any stderr output from ffmpeg
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !stderrData.isEmpty,
           let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stderrStr.isEmpty {
            let exitCode = process.terminationStatus
            if exitCode != 0 {
                log.error("ffmpeg exit=\(exitCode) stderr: \(stderrStr.prefix(500))", source: "Transcode")
            } else {
                log.debug("ffmpeg stderr: \(stderrStr.prefix(200))", source: "Transcode")
            }
        }

        return process.terminationStatus == 0
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

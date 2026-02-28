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

    /// Check cache for a previously transcoded file.
    /// Returns the playable URL immediately on cache hit, otherwise
    /// returns `nil` — caller should then call `transcodeProgressively`.
    func tryFastPath(for url: URL) throws -> URL? {
        guard Self.needsTranscode(url) else { return url }

        // Check in-memory cache
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

        // Check disk (previous session left a result)
        let outURL = outputURL(for: url)
        if FileManager.default.fileExists(atPath: outURL.path) {
            lock.lock()
            cache[url] = outURL
            lock.unlock()
            return outURL
        }

        // No cache — caller should use progressive transcode
        return nil
    }

    /// Start a background transcode that produces an MP4.
    /// The file is written progressively — AVPlayer can start playing
    /// once the first fragments appear on disk.
    ///
    /// **Strategy**: for formats with MP4-compatible codecs (e.g. .insv
    /// with H.264/H.265), try stream-copy first (near-instant output).
    /// Falls back to hardware/software re-encode if stream-copy fails.
    ///
    /// Stream-copy always adds `-tag:v hvc1` so that Apple's
    /// AVFoundation can deliver pixel buffers from HEVC content.
    ///
    /// Call from a detached Task; the method blocks until ffmpeg exits
    /// (or is cancelled).  Check `Task.isCancelled` periodically.
    func transcodeProgressively(for url: URL) throws -> URL {
        guard let ffmpegPath = findFFmpeg() else {
            throw TranscodeError.ffmpegNotFound
        }

        let outURL = outputURL(for: url)
        try? FileManager.default.removeItem(at: outURL)

        isBackgroundTranscoding = true
        defer { isBackgroundTranscoding = false }

        let ext = url.pathExtension.lowercased()

        // --- Dual-fisheye .insv with separate lens tracks ---
        // Two video streams must be merged side-by-side (hstack) and
        // re-encoded so AVPlayer sees a single track.
        if ext == "insv" && probeVideoStreamCount(for: url) >= 2 {
            log.info("Merging dual-stream .insv via hstack for \(url.lastPathComponent)", source: "Transcode")

            // Scale each lens to half-resolution for faster encode,
            // then stack horizontally → 2:1 output.
            let filter = "[0:v:0]scale=iw/2:ih/2[a];[0:v:1]scale=iw/2:ih/2[b];[a][b]hstack=inputs=2"

            var args: [String] = ["-nostdin", "-y", "-hwaccel", "videotoolbox", "-i", url.path]
            args += ["-filter_complex", filter]
            if hasEncoder("hevc_videotoolbox", ffmpegPath: ffmpegPath) {
                args += ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1"]
            } else if hasEncoder("h264_videotoolbox", ffmpegPath: ffmpegPath) {
                args += ["-c:v", "h264_videotoolbox", "-q:v", "65"]
            } else {
                args += ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"]
            }
            args += ["-c:a", "aac", "-b:a", "128k", "-loglevel", "warning", outURL.path]

            let ok = try runFFmpeg(path: ffmpegPath, arguments: args)
            guard ok else {
                try? FileManager.default.removeItem(at: outURL)
                throw TranscodeError.ffmpegFailed(exitCode: -1, message: "Dual-fisheye hstack failed")
            }

            log.info("Dual-fisheye merge complete: \(outURL.lastPathComponent)", source: "Transcode")
            lock.lock()
            cache[url] = outURL
            lock.unlock()
            return outURL
        }

        // --- Attempt 1: stream-copy (remux) ---
        // Skip for codecs known to be MP4-incompatible (WMV3, VP6, etc.).
        if !Self.remuxSkipExtensions.contains(ext) {
            log.info("Trying stream-copy for \(url.lastPathComponent)", source: "Transcode")
            let copyOK = try runFFmpeg(path: ffmpegPath, arguments: [
                "-nostdin", "-y", "-i", url.path,
                "-c", "copy",
                "-tag:v", "hvc1",
                "-loglevel", "warning",
                outURL.path
            ])
            if copyOK {
                log.info("Stream-copy complete: \(outURL.lastPathComponent)", source: "Transcode")
                lock.lock()
                cache[url] = outURL
                lock.unlock()
                return outURL
            }
            try? FileManager.default.removeItem(at: outURL)
            log.info("Stream-copy failed for \(url.lastPathComponent), falling back to re-encode", source: "Transcode")
        }

        // --- Attempt 2: re-encode ---
        let encoderArgs: [String]
        if hasEncoder("h264_videotoolbox", ffmpegPath: ffmpegPath) {
            encoderArgs = ["-c:v", "h264_videotoolbox", "-q:v", "65"]
        } else {
            encoderArgs = ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"]
        }

        log.info("Re-encoding \(url.lastPathComponent) (\(encoderArgs[1]))", source: "Transcode")

        let args: [String] = [
            "-nostdin", "-y", "-i", url.path
        ] + encoderArgs + [
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-loglevel", "error",
            outURL.path
        ]

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

    /// Locate ffprobe – sibling of ffmpeg, then common paths, then $PATH.
    private func findFFprobe() -> String? {
        if let fp = findFFmpeg() {
            let dir = (fp as NSString).deletingLastPathComponent
            let probe = (dir as NSString).appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: probe) { return probe }
        }
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Projection detection

    /// Probe the first video track's width and height via ffprobe.
    /// Returns `(width, height)` or `nil` if probing fails.
    func probeVideoSize(for url: URL) -> (width: Int, height: Int)? {
        guard let ffprobePath = findFFprobe() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            url.path
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let first = streams.first,
              let w = first["width"] as? Int,
              let h = first["height"] as? Int else {
            return nil
        }
        log.debug("Probed video size for \(url.lastPathComponent): \(w)x\(h)", source: "Transcode")
        return (w, h)
    }

    /// Count the number of video streams in the file.
    func probeVideoStreamCount(for url: URL) -> Int {
        guard let ffprobePath = findFFprobe() else { return 0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-select_streams", "v",
            "-show_entries", "stream=index",
            url.path
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return 0
        }
        log.debug("Video stream count for \(url.lastPathComponent): \(streams.count)", source: "Transcode")
        return streams.count
    }

    /// Detect the projection type of a video file.
    ///
    /// For `.insv` files:
    ///   - 2 video streams → dual-fisheye (separate lens tracks)
    ///   - 1 stream, 2:1 aspect (±10 %) → already-stitched equirectangular
    ///   - 1 stream, 1:1 aspect (±10 %) → dual-fisheye (side-by-side in one frame)
    ///   - Otherwise → flat
    ///
    /// Other files are checked for spherical metadata via ffprobe.
    func probeProjection(for url: URL) -> VideoProjection {
        let ext = url.pathExtension.lowercased()

        if ext == "insv" {
            let streamCount = probeVideoStreamCount(for: url)
            if streamCount >= 2 {
                // Two video streams = one per lens → dual-fisheye
                log.info("Detected dual-fisheye .insv (\(streamCount) video streams)", source: "Transcode")
                return .dualFisheye
            }
            // Single stream: check dimensions
            if let size = probeVideoSize(for: url), size.height > 0 {
                let ratio = Double(size.width) / Double(size.height)
                if ratio >= 1.8 && ratio <= 2.2 {
                    log.info("Detected equirectangular .insv (\(size.width)x\(size.height), ratio \(String(format: "%.2f", ratio)))", source: "Transcode")
                    return .equirectangular
                }
                if ratio >= 0.9 && ratio <= 1.1 {
                    log.info("Detected dual-fisheye .insv single-frame (\(size.width)x\(size.height))", source: "Transcode")
                    return .dualFisheye
                }
            }
            log.info(".insv projection unclear for \(url.lastPathComponent), assuming equirectangular", source: "Transcode")
            return .equirectangular
        }

        // For other formats, query ffprobe for spherical metadata
        guard let ffprobePath = findFFprobe() else { return .flat }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams", "-show_format",
            url.path
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .flat
        }

        // Check format-level tags for Google spherical metadata
        if let format = json["format"] as? [String: Any],
           let tags = format["tags"] as? [String: Any] {
            if tags.keys.contains(where: { $0.lowercased().contains("spherical") }) {
                log.info("Detected equirectangular projection (format tags) for \(url.lastPathComponent)", source: "Transcode")
                return .equirectangular
            }
        }

        // Check stream side_data for projection info
        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                // Stream-level tags
                if let tags = stream["tags"] as? [String: Any],
                   tags.keys.contains(where: { $0.lowercased().contains("spherical") }) {
                    log.info("Detected equirectangular projection (stream tags) for \(url.lastPathComponent)", source: "Transcode")
                    return .equirectangular
                }
                // Side data (e.g. "Spherical Mapping" side data type)
                if let sideDataList = stream["side_data_list"] as? [[String: Any]] {
                    for sd in sideDataList {
                        if let sdType = sd["side_data_type"] as? String,
                           sdType.lowercased().contains("spherical") {
                            log.info("Detected equirectangular projection (side_data) for \(url.lastPathComponent)", source: "Transcode")
                            return .equirectangular
                        }
                        if let proj = sd["projection"] as? String,
                           proj.lowercased() == "equirectangular" {
                            log.info("Detected equirectangular projection (projection field) for \(url.lastPathComponent)", source: "Transcode")
                            return .equirectangular
                        }
                    }
                }
            }
        }

        return .flat
    }

    /// Use ffprobe (or ffmpeg) to get the accurate duration of a media file.
    /// Returns the duration in seconds, or nil if it can't be determined.
    /// This works on formats AVFoundation can't read (e.g. .insv).
    func probeDuration(for url: URL) -> Double? {
        if let ffprobePath = findFFprobe() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                url.path
            ]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let format = json["format"] as? [String: Any],
               let durStr = format["duration"] as? String,
               let dur = Double(durStr), dur > 0 {
                log.debug("ffprobe duration for \(url.lastPathComponent): \(dur)s", source: "Transcode")
                return dur
            }
        }

        // Fallback: use ffmpeg -i (prints to stderr)
        if let ffmpegPath = findFFmpeg() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-nostdin", "-i", url.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            try? process.run()
            process.waitUntilExit()

            if let data = try? stderrPipe.fileHandleForReading.readToEnd(),
               let output = String(data: data, encoding: .utf8) {
                // Parse "Duration: HH:MM:SS.xx" from ffmpeg output
                if let range = output.range(of: #"Duration:\s*(\d+):(\d+):(\d+)\.(\d+)"#, options: .regularExpression) {
                    let match = String(output[range])
                    let nums = match.components(separatedBy: CharacterSet(charactersIn: ": .")).compactMap { Double($0) }
                    if nums.count >= 4 {
                        let dur = nums[0] * 3600 + nums[1] * 60 + nums[2] + nums[3] / 100.0
                        if dur > 0 {
                            log.debug("ffmpeg -i duration for \(url.lastPathComponent): \(dur)s", source: "Transcode")
                            return dur
                        }
                    }
                }
            }
        }

        return nil
    }

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

    /// Check whether a specific encoder is available in ffmpeg.
    private func hasEncoder(_ name: String, ffmpegPath: String) -> Bool {
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
        return output.contains(name)
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

        // Capture stderr for diagnostic logging.
        // IMPORTANT: drain it asynchronously to prevent pipe-buffer deadlock.
        // macOS pipe buffers are ~64 KB — if ffmpeg writes more than that
        // (common with v360 filter warnings) and nobody reads, the process
        // blocks on write while we block waiting for it to exit → deadlock.
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        var stderrChunks: [Data] = []
        let stderrLock = NSLock()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrLock.lock()
                stderrChunks.append(chunk)
                stderrLock.unlock()
            }
        }

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
                stderrPipe.fileHandleForReading.readabilityHandler = nil
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

        // Stop draining and collect remaining bytes
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remaining = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        processLock.lock()
        if activeOperationID == operationID {
            activeProcess = nil
            activeOperationID = nil
        }
        processLock.unlock()

        // Assemble captured stderr for logging
        stderrLock.lock()
        if !remaining.isEmpty { stderrChunks.append(remaining) }
        let stderrData = stderrChunks.reduce(Data()) { $0 + $1 }
        stderrLock.unlock()

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

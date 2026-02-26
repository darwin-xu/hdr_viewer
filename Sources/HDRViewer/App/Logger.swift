import Foundation
import os.log

/// Centralized file + console logger for HDR Viewer.
///
/// Log files are written to `~/Library/Logs/HDRViewer/hdrviewer.log`.
/// Each entry is timestamped and tagged with level (DEBUG / INFO / WARNING / ERROR).
/// The logger also forwards messages to os_log so they appear in Console.app.
final class Logger {
    static let shared = Logger()

    enum Level: String {
        case debug   = "DEBUG"
        case info    = "INFO"
        case warning = "WARNING"
        case error   = "ERROR"
    }

    private let fileHandle: FileHandle?
    private let logFilePath: String
    private let queue = DispatchQueue(label: "com.hdrviewer.logger", qos: .utility)
    private let osLogger = os.Logger(subsystem: "com.hdrviewer", category: "app")
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HDRViewer", isDirectory: true)

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logFileURL = logsDir.appendingPathComponent("hdrviewer.log")
        logFilePath = logFileURL.path

        // Rotate if file exceeds 10 MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFilePath),
           let size = attrs[.size] as? UInt64, size > 10_000_000
        {
            let oldPath = logsDir.appendingPathComponent("hdrviewer.old.log").path
            try? FileManager.default.removeItem(atPath: oldPath)
            try? FileManager.default.moveItem(atPath: logFilePath, toPath: oldPath)
        }

        if !FileManager.default.fileExists(atPath: logFilePath) {
            FileManager.default.createFile(atPath: logFilePath, contents: nil)
        }

        fileHandle = FileHandle(forWritingAtPath: logFilePath)
        fileHandle?.seekToEndOfFile()

        info("Logger initialized — log file: \(logFilePath)", source: "Logger")
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public API

    func debug(_ message: String, source: String = "App") {
        log(level: .debug, message: message, source: source)
    }

    func info(_ message: String, source: String = "App") {
        log(level: .info, message: message, source: source)
    }

    func warning(_ message: String, source: String = "App") {
        log(level: .warning, message: message, source: source)
    }

    func error(_ message: String, source: String = "App") {
        log(level: .error, message: message, source: source)
    }

    // MARK: - Stderr Capture

    /// Redirect stderr to the log file so system-level messages
    /// (AttributeGraph warnings, IMK errors, etc.) are captured instead
    /// of cluttering the Xcode console.
    func redirectStderrToLogFile() {
        guard let fileHandle else { return }
        let fd = fileHandle.fileDescriptor
        // dup2 redirects STDERR_FILENO → our log file descriptor
        dup2(fd, STDERR_FILENO)
        info("stderr redirected to log file", source: "Logger")
    }

    // MARK: - Internal

    private func log(level: Level, message: String, source: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] [\(source)] \(message)\n"

        // os_log (Console.app)
        switch level {
        case .debug:   osLogger.debug("\(line, privacy: .public)")
        case .info:    osLogger.info("\(line, privacy: .public)")
        case .warning: osLogger.warning("\(line, privacy: .public)")
        case .error:   osLogger.error("\(line, privacy: .public)")
        }

        // File
        queue.async { [weak self] in
            if let data = line.data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
        }
    }
}

import Foundation
import OSLog

/// Two-headed logger: writes to Apple's unified log (so `log show` works)
/// AND appends to `~/Documents/Transcriberr/transcriberr.log` so we can
/// inspect it after a crash or silent failure.
enum AppLog {
    private static let subsystem = "nl.ihnatov.Transcriberr"
    private static let queue = DispatchQueue(label: "AppLog.io")
    private static let osLogger = Logger(subsystem: subsystem, category: "general")

    static let logFileURL: URL = {
        // ~/Library/Logs is the macOS home for app logs. The old location
        // (~/Documents/Transcriberr) doubles as the project folder AND the
        // recordings home — a transcript-bearing log does not belong there.
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Transcriberr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcriberr.log")
    }()

    /// One header line per app launch.
    static func bootBanner() {
        write(level: "BOOT", category: "app",
              message: "Transcriberr launched – pid \(ProcessInfo.processInfo.processIdentifier)")
    }

    static func info(_ category: String, _ message: @autoclosure () -> String) {
        let m = message()
        osLogger.info("[\(category, privacy: .public)] \(m, privacy: .public)")
        write(level: "INFO", category: category, message: m)
    }

    static func warn(_ category: String, _ message: @autoclosure () -> String) {
        let m = message()
        osLogger.warning("[\(category, privacy: .public)] \(m, privacy: .public)")
        write(level: "WARN", category: category, message: m)
    }

    static func error(_ category: String, _ message: @autoclosure () -> String) {
        let m = message()
        osLogger.error("[\(category, privacy: .public)] \(m, privacy: .public)")
        write(level: "ERR ", category: category, message: m)
    }

    // MARK: - File I/O

    private static let maxFileBytes = 5 * 1024 * 1024
    private static var didOpenFile = false
    private static var handle: FileHandle?

    private static func write(level: String, category: String, message: String) {
        let line = "\(timestamp()) \(level) [\(category)] \(message)\n"
        queue.async {
            ensureOpen()
            if let data = line.data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
        }
    }

    private static func ensureOpen() {
        guard !didOpenFile else { return }
        didOpenFile = true
        let fm = FileManager.default
        // The log carries transcript snippets and recording titles: owner-only,
        // and capped — one rotation at launch keeps at most ~2× the limit.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if let size = (try? fm.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
           size > maxFileBytes {
            let old = logFileURL.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logFileURL, to: old)
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: Data(), attributes: ownerOnly)
        }
        try? fm.setAttributes(ownerOnly, ofItemAtPath: logFileURL.path)
        if let h = try? FileHandle(forWritingTo: logFileURL) {
            try? h.seekToEnd()
            handle = h
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}

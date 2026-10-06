import Foundation
import os

/// Minimal logging: stderr (when attached to a terminal) plus a rotating file.
///
/// There is no telemetry, no analytics and no network logging of any kind. The
/// log deliberately records identifiers and error descriptions only, never
/// image data.
enum Log {
    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var handle: FileHandle?
        var toStderr = isatty(STDERR_FILENO) == 1
        var failed = false
    }

    private static let maxLogBytes = 5 * 1024 * 1024

    static func start() {
        let url = AppPaths.logFile
        try? AppPaths.createDirectoryIfNeeded(url.deletingLastPathComponent())
        rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        state.withLock { $0.handle = handle }
    }

    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > maxLogBytes else { return }
        let rotated = url.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    static func info(_ message: String) { write(.info, message) }
    static func warn(_ message: String) { write(.warn, message) }
    static func error(_ message: String) { write(.error, message) }

    private static func write(_ level: Level, _ message: String) {
        let stamp = Date().formatted(.iso8601)
        let line = "\(stamp) [\(level.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let stderrEnabled = state.withLock { current -> Bool in
            if let handle = current.handle, !current.failed {
                do { try handle.write(contentsOf: data) } catch { current.failed = true }
            }
            return current.toStderr
        }
        if stderrEnabled {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}

import Foundation
import Logging
import Synchronization

/// Factory for creating file-based loggers for VMs.
/// Each component picks its own label when calling `logger(for:)` (e.g. "runner", "vsock-guest-agent").
public enum VMLogger {
    private static let cacheMutex = Mutex<[String: LogHandler]>([:])
    private static let fileHandles = Mutex<[String: FileHandle]>([:])

    /// Returns a multiplex (file + stderr) logger for the given component label.
    /// Uses LogContext.current when set; otherwise stderr-only. Handlers are cached per (label, path).
    /// All handlers for the same log path share a single FileHandle.
    /// Minimum log level is taken from the `VM_LOG_LEVEL` environment variable when the handler is created.
    public static func logger(for componentLabel: String) -> Logger {
        let context = LogContext.current
        let pathString = context?.logPath.path ?? ""
        let cacheKey = "\(componentLabel)|\(pathString)"

        let handler = cacheMutex.withLock { cache in
            if let cached = cache[cacheKey] {
                return cached
            }
            var newHandler: LogHandler
            if let logPath = context?.logPath {
                do {
                    let fh = try getOrCreateHandle(for: logPath, key: pathString)
                    let fileHandler = FileLogHandler(label: componentLabel, fileHandle: fh)
                    newHandler = MultiplexLogHandler([
                        fileHandler,
                        StreamLogHandler.standardError(label: componentLabel),
                    ])
                } catch {
                    newHandler = StreamLogHandler.standardError(label: componentLabel)
                }
            } else {
                newHandler = StreamLogHandler.standardError(label: componentLabel)
            }
            newHandler.logLevel =
                Logger.Level(
                    rawValue: ProcessInfo.processInfo.environment["VM_LOG_LEVEL"]?.lowercased()
                        ?? "info") ?? .info
            cache[cacheKey] = newHandler
            return newHandler
        }
        return Logger(label: componentLabel, factory: { _ in handler })
    }

    /// Closes all open log file handles and clears the handler cache.
    /// Call during process shutdown to release log file descriptors deterministically.
    public static func shutdown() {
        cacheMutex.withLock { $0.removeAll() }
        fileHandles.withLock { handles in
            for (_, fh) in handles {
                try? fh.close()
            }
            handles.removeAll()
        }
    }

    private static func getOrCreateHandle(for logPath: URL, key: String) throws -> FileHandle {
        try fileHandles.withLock { handles in
            if let existing = handles[key] {
                return existing
            }
            let fm = FileManager.default
            if !fm.fileExists(atPath: logPath.path) {
                fm.createFile(atPath: logPath.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: logPath)
            try fh.seekToEnd()
            handles[key] = fh
            return fh
        }
    }
}

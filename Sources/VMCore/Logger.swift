import Logging
import Synchronization

/// Factory for creating file-based loggers for VMs.
/// Each component picks its own label when calling `logger(for:)` (e.g. "runner", "vsock-guest-agent").
public enum VMLogger {
    private static let cacheMutex = Mutex<[String: LogHandler]>([:])

    /// Returns a multiplex (file + stderr) logger for the given component label.
    /// Uses LogContext.current when set; otherwise stderr-only. Handlers are cached per (label, path).
    public static func logger(for componentLabel: String) -> Logger {
        let context = LogContext.current
        let pathString = context?.logPath.path ?? ""
        let cacheKey = "\(componentLabel)|\(pathString)"

        let handler = cacheMutex.withLock { cache in
            if let cached = cache[cacheKey] {
                return cached
            }
            let newHandler: LogHandler
            if let logPath = context?.logPath {
                do {
                    let fileHandler = try FileLogHandler(label: componentLabel, fileURL: logPath)
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
            cache[cacheKey] = newHandler
            return newHandler
        }
        return Logger(label: componentLabel, factory: { _ in handler })
    }
}

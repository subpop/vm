import Foundation
import Synchronization

/// Process-wide log context used by component loggers to resolve the VM log file path.
/// Set by the daemon at start; when nil, component loggers fall back to stderr-only.
public struct LogState: Sendable {
    public let vmName: String
    public let logPath: URL

    public init(vmName: String, logPath: URL) {
        self.vmName = vmName
        self.logPath = logPath
    }
}

/// Thread-safe access to the current log context.
public enum LogContext {
    private static let mutex = Mutex<LogState?>(nil)

    /// Current process log context. Set by the daemon at start; nil when not in a daemon.
    public static var current: LogState? {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

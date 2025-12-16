import Synchronization

/// Thread-safe flag for signaling exit across concurrency boundaries
public final class ExitFlag: Sendable {
    private let mutex = Mutex(false)

    public init() {}

    public var shouldExit: Bool {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}


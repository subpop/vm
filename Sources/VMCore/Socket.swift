import Foundation
import Synchronization

/// Errors that can occur during socket operations
public enum SocketError: Error, LocalizedError, Sendable, Equatable {
    case invalidDescriptor
    case addressTooLong
    case systemError(errno: Int32, description: String)
    case disconnected
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            return "Invalid socket descriptor"
        case .addressTooLong:
            return "Socket path exceeds maximum length (104 bytes)"
        case .systemError(let errno, let description):
            return "Socket error (\(errno)): \(description)"
        case .disconnected:
            return "Socket disconnected"
        case .timeout:
            return "Socket operation timed out"
        }
    }
}

/// A Swift 6 async/await wrapper for BSD UNIX domain sockets
public final class Socket: Sendable {
    /// The underlying file descriptor
    private let fd: Int32

    /// State tracking for the socket
    private let state: SocketState

    /// Thread-safe state wrapper using Swift 6 Mutex
    private final class SocketState: Sendable {
        /// Internal state protected by a mutex
        private struct State: ~Copyable {
            var isClosed = false
            var boundPath: String?
        }

        private let mutex = Mutex(State())

        var isClosed: Bool {
            get { mutex.withLock { $0.isClosed } }
            set { mutex.withLock { $0.isClosed = newValue } }
        }

        var boundPath: String? {
            get { mutex.withLock { $0.boundPath } }
            set { mutex.withLock { $0.boundPath = newValue } }
        }
    }

    /// Creates a new UNIX domain socket
    public init() throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.systemError(
                errno: errno,
                description: String(cString: strerror(errno))
            )
        }
        self.fd = descriptor
        self.state = SocketState()
    }

    /// Internal initializer for accepted connections
    private init(fileDescriptor: Int32) {
        self.fd = fileDescriptor
        self.state = SocketState()
    }

    deinit {
        if !state.isClosed {
            Darwin.close(fd)
            if let path = state.boundPath {
                unlink(path)
            }
        }
    }

    /// The file descriptor for this socket
    public var fileDescriptor: Int32 {
        fd
    }

    /// Whether the socket has been closed
    public var isClosed: Bool {
        state.isClosed
    }

    /// Connects to a UNIX domain socket at the specified path
    /// - Parameter path: The filesystem path to the socket
    public func connect(to path: String) async throws {
        guard !state.isClosed else {
            throw SocketError.invalidDescriptor
        }

        var addr = try makeSocketAddress(path: path)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            throw SocketError.systemError(
                errno: errno,
                description: String(cString: strerror(errno))
            )
        }
    }

    /// Binds the socket to a path for listening
    /// - Parameter path: The filesystem path where the socket will be created
    public func bind(to path: String) throws {
        guard !state.isClosed else {
            throw SocketError.invalidDescriptor
        }

        // Remove existing socket file if present
        Darwin.unlink(path)

        var addr = try makeSocketAddress(path: path)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            throw SocketError.systemError(
                errno: errno,
                description: String(cString: strerror(errno))
            )
        }

        state.boundPath = path
    }

    /// Starts listening for incoming connections
    /// - Parameter backlog: Maximum number of pending connections
    public func listen(backlog: Int32 = 5) throws {
        guard !state.isClosed else {
            throw SocketError.invalidDescriptor
        }

        let result = Darwin.listen(fd, backlog)
        guard result == 0 else {
            throw SocketError.systemError(
                errno: errno,
                description: String(cString: strerror(errno))
            )
        }
    }

    /// Accepts an incoming connection asynchronously
    /// - Returns: A new Socket for the accepted connection
    public func accept() async throws -> Socket {
        guard !state.isClosed else {
            throw SocketError.invalidDescriptor
        }

        // Set non-blocking mode for async operation
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        return try await withCheckedThrowingContinuation { continuation in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue.global()
            )

            source.setEventHandler { [fd] in
                source.cancel()

                var clientAddr = sockaddr_un()
                var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(fd, sockaddrPtr, &addrLen)
                    }
                }

                if clientFD >= 0 {
                    continuation.resume(returning: Socket(fileDescriptor: clientFD))
                } else {
                    continuation.resume(
                        throwing: SocketError.systemError(
                            errno: errno,
                            description: String(cString: strerror(errno))
                        ))
                }
            }

            source.setCancelHandler {
                // Cleanup if needed
            }

            source.resume()
        }
    }

    /// Sends data through the socket
    /// - Parameter data: The data to send
    public func send(_ data: Data) async throws {
        guard !state.isClosed else {
            throw SocketError.invalidDescriptor
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    continuation.resume(throwing: SocketError.invalidDescriptor)
                    return
                }

                var totalSent = 0
                let totalBytes = data.count

                while totalSent < totalBytes {
                    let sent = Darwin.send(
                        fd,
                        baseAddress.advanced(by: totalSent),
                        totalBytes - totalSent,
                        0
                    )

                    if sent > 0 {
                        totalSent += sent
                    } else if sent == 0 {
                        continuation.resume(throwing: SocketError.disconnected)
                        return
                    } else {
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            // Would block, continue trying
                            continue
                        }
                        continuation.resume(
                            throwing: SocketError.systemError(
                                errno: errno,
                                description: String(cString: strerror(errno))
                            ))
                        return
                    }
                }

                continuation.resume()
            }
        }
    }

    /// Receives data from the socket
    /// - Parameter maxBytes: Maximum number of bytes to receive
    /// - Returns: The received data, or empty data if the connection was closed
    public func receive(maxBytes: Int = 4096) async throws -> Data {
        guard !state.isClosed else {
            throw SocketError.invalidDescriptor
        }

        // Set non-blocking mode for async operation
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        return try await withCheckedThrowingContinuation { continuation in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue.global()
            )

            source.setEventHandler { [fd] in
                source.cancel()

                var buffer = [UInt8](repeating: 0, count: maxBytes)
                let bytesRead = Darwin.recv(fd, &buffer, maxBytes, 0)

                if bytesRead > 0 {
                    continuation.resume(returning: Data(buffer.prefix(bytesRead)))
                } else if bytesRead == 0 {
                    // Connection closed gracefully
                    continuation.resume(returning: Data())
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        // No data available, return empty
                        continuation.resume(returning: Data())
                    } else {
                        continuation.resume(
                            throwing: SocketError.systemError(
                                errno: errno,
                                description: String(cString: strerror(errno))
                            ))
                    }
                }
            }

            source.setCancelHandler {
                // Cleanup if needed
            }

            source.resume()
        }
    }

    /// Returns an AsyncStream that continuously receives data from the socket
    /// - Parameter maxBytes: Maximum number of bytes to receive per chunk
    /// - Returns: An AsyncStream that yields Data chunks until the socket closes or errors
    public func receiveStream(maxBytes: Int = 4096) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    while !self.isClosed {
                        let data = try await self.receive(maxBytes: maxBytes)
                        if data.isEmpty {
                            // Connection closed gracefully
                            break
                        }
                        continuation.yield(data)
                    }
                } catch {
                    // Socket error, stop streaming
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Closes the socket and cleans up resources
    public func close() {
        guard !state.isClosed else { return }

        state.isClosed = true
        Darwin.close(fd)

        // Remove the socket file if we bound to a path
        if let path = state.boundPath {
            unlink(path)
            state.boundPath = nil
        }
    }

    // MARK: - Private Helpers

    /// Creates a sockaddr_un structure for the given path
    private func makeSocketAddress(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)

        guard pathBytes.count <= maxPathLength else {
            throw SocketError.addressTooLong
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { pathPtr in
                ptr.copyMemory(from: pathPtr)
            }
        }

        return addr
    }
}

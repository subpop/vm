import Foundation
import Synchronization

/// Error types for console listener operations
public enum ConsoleListenerError: Error, LocalizedError, Sendable {
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Listener is already running"
        }
    }
}

/// Thread-safe buffer for recent console output
private final class OutputBuffer: Sendable {
    private let mutex = Mutex(Data())
    private let maxSize = 8192  // Keep last 8KB of output

    func append(_ data: Data) {
        mutex.withLock { buffer in
            buffer.append(Self.stripEscapeSequences(data))
            if buffer.count > maxSize {
                buffer = buffer.suffix(maxSize)
            }
        }
    }

    func getAndClear() -> Data {
        mutex.withLock { buffer in
            let result = buffer
            buffer = Data()
            return result
        }
    }

    func get() -> Data {
        mutex.withLock { $0 }
    }

    /// Strips all ANSI escape sequences from data, keeping only visible text.
    private static func stripEscapeSequences(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)

        var i = 0
        while i < data.count {
            if data[i] == 0x1B {  // ESC
                i += 1
                guard i < data.count else { break }

                if data[i] == 0x5B {  // CSI sequence: ESC[
                    i += 1
                    // Skip until final byte (0x40-0x7E)
                    while i < data.count && !(data[i] >= 0x40 && data[i] <= 0x7E) {
                        i += 1
                    }
                    if i < data.count { i += 1 }  // Skip final byte
                } else {
                    // Other ESC sequence (e.g., ESC D, ESC M) - skip one byte
                    i += 1
                }
            } else {
                result.append(data[i])
                i += 1
            }
        }

        return result
    }
}

/// Tracks a connected client with its socket and read task
private struct ClientConnection: Sendable {
    let socket: Socket
    let readTask: Task<Void, Never>
}

/// Manages console I/O multiplexing between VM serial port and multiple client connections
/// Uses the Socket class for Unix domain socket operations
@MainActor
public final class ConsoleListener {
    private let socketPath: URL
    private let vmInput: FileHandle
    private let vmOutput: FileHandle

    private var serverSocket: Socket?
    private var acceptTask: Task<Void, Never>?
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    private var isRunning = false
    private let outputBuffer = OutputBuffer()

    public init(socketPath: URL, vmInput: FileHandle, vmOutput: FileHandle) {
        self.socketPath = socketPath
        self.vmInput = vmInput
        self.vmOutput = vmOutput
    }

    /// Starts the console listener
    public func start() async throws {
        guard !isRunning else {
            throw ConsoleListenerError.alreadyRunning
        }

        // Remove existing socket file if present
        try? FileManager.default.removeItem(at: socketPath)

        // Create and configure server socket
        let socket = try Socket()
        try socket.bind(to: socketPath.path)
        try socket.listen(backlog: 5)
        serverSocket = socket

        isRunning = true

        // Start accepting connections in background
        acceptTask = Task { [weak self] in
            await self?.acceptLoop()
        }

        // Start reading from VM output and broadcasting to clients
        startVMOutputForwarding()
    }

    /// Stops the console listener
    public func stop() async {
        guard isRunning else { return }

        isRunning = false

        // Stop accepting new connections
        acceptTask?.cancel()
        acceptTask = nil

        // Disconnect all clients
        for (_, client) in clients {
            client.readTask.cancel()
            client.socket.close()
        }
        clients.removeAll()

        // Close server socket (also removes the socket file via Socket's cleanup)
        serverSocket?.close()
        serverSocket = nil

        // Stop VM output forwarding
        vmOutput.readabilityHandler = nil
    }

    /// Continuously accepts incoming client connections
    private func acceptLoop() async {
        guard let server = serverSocket else { return }

        while !Task.isCancelled && isRunning {
            do {
                let clientSocket = try await server.accept()
                await handleNewClient(clientSocket)
            } catch {
                // Accept failed - if we're still running, log and continue
                if isRunning && !Task.isCancelled {
                    // Brief delay before retrying to avoid tight error loop
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// Handles a newly connected client
    private func handleNewClient(_ clientSocket: Socket) async {
        let clientID = ObjectIdentifier(clientSocket)

        // Send any buffered output to the new client so they see recent context
        let bufferedOutput = outputBuffer.get()
        if !bufferedOutput.isEmpty {
            do {
                try await clientSocket.send(bufferedOutput)
            } catch {
                // Failed to send initial buffer, close connection
                clientSocket.close()
                return
            }
        }

        // Start reading from this client in background
        let readTask = Task { [weak self] in
            guard let self = self else { return }
            await self.readFromClient(clientSocket, clientID: clientID)
        }

        clients[clientID] = ClientConnection(socket: clientSocket, readTask: readTask)
    }

    /// Reads data from a client and forwards to VM
    private func readFromClient(_ clientSocket: Socket, clientID: ObjectIdentifier) async {
        for await data in clientSocket.receiveStream() {
            // Forward client input to VM
            try? vmInput.write(contentsOf: data)
        }

        // Client disconnected - clean up on main actor
        await MainActor.run {
            disconnectClient(clientID: clientID)
        }
    }

    /// Disconnects a client by ID
    private func disconnectClient(clientID: ObjectIdentifier) {
        if let client = clients.removeValue(forKey: clientID) {
            client.readTask.cancel()
            client.socket.close()
        }
    }

    /// Forwards VM output to all connected clients
    private func startVMOutputForwarding() {
        let buffer = outputBuffer
        vmOutput.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if !data.isEmpty {
                // Buffer the output for new clients
                buffer.append(data)
                Task { @MainActor in
                    await self.broadcastToClients(data)
                }
            }
        }
    }

    /// Broadcasts data to all connected clients
    private func broadcastToClients(_ data: Data) async {
        var disconnected: [ObjectIdentifier] = []

        for (clientID, client) in clients {
            do {
                try await client.socket.send(data)
            } catch {
                // Send failed - mark for disconnection
                disconnected.append(clientID)
            }
        }

        // Clean up disconnected clients
        for clientID in disconnected {
            disconnectClient(clientID: clientID)
        }
    }
}

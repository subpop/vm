import Foundation

/// Error types for console connection operations
public enum ConsoleConnectionError: Error, LocalizedError, Sendable {
    case notATerminal
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notATerminal:
            return "Not running in a terminal"
        case .connectionFailed(let reason):
            return "Failed to connect to console: \(reason)"
        }
    }
}

/// Manages a connection to a running VM's console via Unix socket
/// Uses the Socket class for Unix domain socket operations
@MainActor
public final class ConsoleConnection {
    private let vmName: String
    private let socketPath: URL
    private let messageHandler: ((String) -> Void)?
    private var socket: Socket?
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false
    private let exitFlag = ExitFlag()

    public init(vmName: String, socketPath: URL, messageHandler: ((String) -> Void)? = nil) {
        self.vmName = vmName
        self.socketPath = socketPath
        self.messageHandler = messageHandler
    }

    /// Connects to the VM console socket
    public func connect() async throws {
        let terminal = TerminalController.shared

        // Check if we have a terminal
        guard terminal.isTerminal else {
            throw ConsoleConnectionError.notATerminal
        }

        // Create and connect socket
        let newSocket = try Socket()
        do {
            try await newSocket.connect(to: socketPath.path)
        } catch {
            newSocket.close()
            throw ConsoleConnectionError.connectionFailed(error.localizedDescription)
        }

        socket = newSocket
        isConnected = true
    }

    /// Runs the interactive console session
    /// Returns when the user detaches (Ctrl-]) or the connection is lost
    public func run() async throws {
        guard let socket = socket, isConnected else {
            throw ConsoleConnectionError.connectionFailed("Not connected")
        }

        let terminal = TerminalController.shared

        // Enable raw mode
        try terminal.enableRawMode()

        // Track if we need to restore terminal mode (for error paths)
        var rawModeEnabled = true

        defer {
            if rawModeEnabled {
                terminal.disableRawMode()
            }
        }

        exitFlag.shouldExit = false

        let exitFlagRef = exitFlag
        let socketRef = socket

        // Set up stdin forwarding to socket using FileHandle's readabilityHandler
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF
                exitFlagRef.shouldExit = true
                return
            }

            // Check for Ctrl-] (0x1D) to exit
            if data.contains(0x1D) {
                exitFlagRef.shouldExit = true
                return
            }

            // Write to socket asynchronously
            Task {
                do {
                    try await socketRef.send(data)
                } catch {
                    exitFlagRef.shouldExit = true
                }
            }
        }

        // Start receiving from socket in background
        receiveTask = Task {
            for await data in socket.receiveStream(maxBytes: 65536) {
                // Write to stdout
                try? FileHandle.standardOutput.write(contentsOf: data)
            }
            // Socket closed or errored
            exitFlagRef.shouldExit = true
        }

        // Wait for exit signal
        while !exitFlag.shouldExit {
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        // Clean up before restoring terminal mode
        FileHandle.standardInput.readabilityHandler = nil
        receiveTask?.cancel()
        receiveTask = nil

        // Close the socket so the listener knows we disconnected
        socket.close()
        self.socket = nil
        isConnected = false

        // Restore terminal mode BEFORE outputting messages so they are formatted correctly
        terminal.disableRawMode()
        rawModeEnabled = false

        messageHandler?("\nDetached from VM console")
        messageHandler?("VM continues running. Use 'vm stop \(vmName)' to stop it")
    }

    /// Disconnects from the console
    public func disconnect() async {
        exitFlag.shouldExit = true

        FileHandle.standardInput.readabilityHandler = nil

        receiveTask?.cancel()
        receiveTask = nil

        socket?.close()
        socket = nil

        isConnected = false
    }
}

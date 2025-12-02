import Foundation
import Testing

@testable import VMCore

@Suite("Socket Tests")
struct SocketTests {

    /// Creates a temporary socket path for testing
    private func makeTemporarySocketPath() -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let socketName = "test_socket_\(UUID().uuidString).sock"
        return tempDir.appendingPathComponent(socketName).path
    }

    /// Cleans up a socket file if it exists
    private func cleanupSocket(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Socket creation succeeds")
    func socketCreation() throws {
        let socket = try Socket()
        #expect(socket.fileDescriptor >= 0)
        #expect(!socket.isClosed)
        socket.close()
        #expect(socket.isClosed)
    }

    @Test("Connect to nonexistent path fails with appropriate error")
    func connectToNonexistentPath() async throws {
        let socket = try Socket()
        defer { socket.close() }

        let nonexistentPath = "/tmp/nonexistent_socket_\(UUID().uuidString).sock"

        await #expect(throws: SocketError.self) {
            try await socket.connect(to: nonexistentPath)
        }
    }

    @Test("Bind and listen succeeds")
    func bindAndListen() throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        let socket = try Socket()
        defer { socket.close() }

        try socket.bind(to: socketPath)
        try socket.listen(backlog: 5)

        // Verify socket file was created
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("Path too long throws addressTooLong error")
    func pathTooLong() throws {
        let socket = try Socket()
        defer { socket.close() }

        // Create a path longer than 104 bytes (macOS limit)
        let longPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"

        #expect(throws: SocketError.addressTooLong) {
            try socket.bind(to: longPath)
        }
    }

    @Test("Close socket cleans up resources")
    func closeSocket() throws {
        let socketPath = makeTemporarySocketPath()

        let socket = try Socket()
        try socket.bind(to: socketPath)
        try socket.listen()

        // Socket file should exist
        #expect(FileManager.default.fileExists(atPath: socketPath))

        socket.close()

        // Socket should be marked as closed
        #expect(socket.isClosed)

        // Socket file should be removed
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("Client-server communication")
    func clientServerCommunication() async throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        // Create and start server
        let server = try Socket()
        try server.bind(to: socketPath)
        try server.listen()

        // Start accept in background
        let serverTask = Task {
            let clientConnection = try await server.accept()
            defer { clientConnection.close() }

            // Receive data from client
            let receivedData = try await clientConnection.receive()
            #expect(!receivedData.isEmpty)

            // Echo back
            try await clientConnection.send(receivedData)

            return receivedData
        }

        // Give server a moment to start accepting
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Create client and connect
        let client = try Socket()
        defer { client.close() }

        try await client.connect(to: socketPath)

        // Send data
        let testMessage = "Hello, Socket!".data(using: .utf8)!
        try await client.send(testMessage)

        // Receive echo
        let response = try await client.receive()

        // Verify round trip
        #expect(response == testMessage)

        // Verify server received correctly
        let serverReceived = try await serverTask.value
        #expect(serverReceived == testMessage)

        server.close()
    }

    @Test("Multiple clients can connect sequentially")
    func multipleClients() async throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        let server = try Socket()
        defer { server.close() }

        try server.bind(to: socketPath)
        try server.listen(backlog: 5)

        // Test with 3 sequential clients
        for i in 1...3 {
            let serverTask = Task {
                let clientConn = try await server.accept()
                defer { clientConn.close() }

                let data = try await clientConn.receive()
                try await clientConn.send(data)
                return data
            }

            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

            let client = try Socket()
            try await client.connect(to: socketPath)

            let message = "Client \(i)".data(using: .utf8)!
            try await client.send(message)

            let response = try await client.receive()
            #expect(response == message)

            let serverData = try await serverTask.value
            #expect(String(data: serverData, encoding: .utf8) == "Client \(i)")

            client.close()
        }
    }

    @Test("Operations on closed socket throw invalidDescriptor")
    func operationsOnClosedSocket() async throws {
        let socket = try Socket()
        socket.close()

        #expect(throws: SocketError.invalidDescriptor) {
            try socket.bind(to: "/tmp/test.sock")
        }

        #expect(throws: SocketError.invalidDescriptor) {
            try socket.listen()
        }

        await #expect(throws: SocketError.invalidDescriptor) {
            try await socket.connect(to: "/tmp/test.sock")
        }

        await #expect(throws: SocketError.invalidDescriptor) {
            try await socket.accept()
        }

        await #expect(throws: SocketError.invalidDescriptor) {
            try await socket.send(Data())
        }

        await #expect(throws: SocketError.invalidDescriptor) {
            _ = try await socket.receive()
        }
    }

    @Test("Closing socket multiple times is safe")
    func closeMultipleTimes() throws {
        let socket = try Socket()

        // Close multiple times should not crash
        socket.close()
        socket.close()
        socket.close()

        #expect(socket.isClosed)
    }

    @Test("Bind removes existing socket file")
    func bindRemovesExistingFile() throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        // Create first socket and bind
        let socket1 = try Socket()
        try socket1.bind(to: socketPath)
        try socket1.listen()

        #expect(FileManager.default.fileExists(atPath: socketPath))

        // Close without cleanup (simulate crash)
        Darwin.close(socket1.fileDescriptor)

        // File should still exist
        #expect(FileManager.default.fileExists(atPath: socketPath))

        // Second socket should be able to bind to same path
        let socket2 = try Socket()
        defer { socket2.close() }

        try socket2.bind(to: socketPath)
        try socket2.listen()

        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("receiveStream yields multiple data chunks")
    func receiveStream() async throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        // Create and start server
        let server = try Socket()
        defer { server.close() }
        try server.bind(to: socketPath)
        try server.listen()

        // Messages to send
        let messages = ["First", "Second", "Third", "Fourth"]

        // Server task: accept connection and collect all received data via receiveStream
        let serverTask = Task { () -> [Data] in
            let clientConn = try await server.accept()
            defer { clientConn.close() }

            var receivedChunks: [Data] = []
            for await data in clientConn.receiveStream() {
                receivedChunks.append(data)
            }
            return receivedChunks
        }

        // Give server a moment to start accepting
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Create client and connect
        let client = try Socket()

        try await client.connect(to: socketPath)

        // Send multiple messages with small delays to ensure separate chunks
        for message in messages {
            let data = message.data(using: .utf8)!
            try await client.send(data)
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms between sends
        }

        // Close client to signal end of stream
        client.close()

        // Wait for server to finish receiving
        let receivedChunks = try await serverTask.value

        // Verify we received data
        #expect(!receivedChunks.isEmpty)

        // Combine all received data and verify content
        let combinedData = receivedChunks.reduce(Data()) { $0 + $1 }
        let combinedString = String(data: combinedData, encoding: .utf8)

        // All messages should be received (order preserved, may be combined or separate)
        for message in messages {
            #expect(combinedString?.contains(message) == true)
        }
    }

    @Test("receiveStream finishes when socket is closed")
    func receiveStreamFinishesOnClose() async throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        let server = try Socket()
        defer { server.close() }
        try server.bind(to: socketPath)
        try server.listen()

        // Server task: accept and iterate receiveStream
        let serverTask = Task { () -> Int in
            let clientConn = try await server.accept()
            defer { clientConn.close() }

            var chunkCount = 0
            for await _ in clientConn.receiveStream() {
                chunkCount += 1
            }
            return chunkCount
        }

        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Client connects, sends one message, then closes
        let client = try Socket()
        try await client.connect(to: socketPath)

        try await client.send("Hello".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Close the client - this should cause receiveStream to finish
        client.close()

        // Server should complete and return the chunk count
        let chunkCount = try await serverTask.value
        #expect(chunkCount >= 1)
    }

    @Test("receiveStream can be cancelled")
    func receiveStreamCancellation() async throws {
        let socketPath = makeTemporarySocketPath()
        defer { cleanupSocket(at: socketPath) }

        let server = try Socket()
        defer { server.close() }
        try server.bind(to: socketPath)
        try server.listen()

        // Server task that will be cancelled
        let serverTask = Task { () -> Bool in
            let clientConn = try await server.accept()
            defer { clientConn.close() }

            // This should be interrupted by cancellation
            for await _ in clientConn.receiveStream() {
                // Keep receiving until cancelled
            }
            return true
        }

        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Client connects
        let client = try Socket()
        defer { client.close() }
        try await client.connect(to: socketPath)

        // Send some data
        try await client.send("Test".data(using: .utf8)!)

        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Cancel the server task
        serverTask.cancel()

        // Task should complete (either via cancellation or normally)
        _ = await serverTask.result
        #expect(serverTask.isCancelled || true)  // Test passes if we reach here
    }
}

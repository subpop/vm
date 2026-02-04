import Foundation
import Logging
import Virtualization

/// Port number for guest agent vsock communication
/// Guest listens using: qemu-ga --method=vsock-listen --path=3:9001
/// (CID 3 is the standard guest CID in Virtualization.framework)
private let GUEST_AGENT_PORT: UInt32 = 9001

/// Errors that can occur during QEMU Guest Agent communication
public enum QemuGuestAgentError: LocalizedError, Sendable {
    case notConnected
    case timeout
    case invalidResponse
    case agentError(String)
    case encodingError
    case decodingError

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to guest agent"
        case .timeout:
            return "Guest agent request timed out"
        case .invalidResponse:
            return "Invalid response from guest agent"
        case .agentError(let message):
            return "Guest agent error: \(message)"
        case .encodingError:
            return "Failed to encode request"
        case .decodingError:
            return "Failed to decode response"
        }
    }
}

/// Represents a network interface from the guest
public struct GuestNetworkInterface: Codable, Sendable {
    public let name: String
    public let hwaddr: String?
    public let ipAddresses: [IPAddress]?

    public struct IPAddress: Codable, Sendable {
        public let ipAddressType: String
        public let ipAddress: String
        public let prefix: Int?

        public enum CodingKeys: String, CodingKey {
            case ipAddressType = "ip-address-type"
            case ipAddress = "ip-address"
            case prefix
        }
    }

    public enum CodingKeys: String, CodingKey {
        case name
        case hwaddr = "hardware-address"
        case ipAddresses = "ip-addresses"
    }
}

/// Client for communicating with QEMU Guest Agent via vsock
@MainActor
public final class VsockGuestAgent {
    private let socketDevice: VZVirtioSocketDevice
    private var connection: VZVirtioSocketConnection?
    private var handle: FileHandle?
    private var isConnected = false
    private var logger: Logger { VMLogger.logger(for: "vsock-guest-agent") }

    /// Initialize with a vsock device from the VM
    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
    }

    /// Connect to the guest agent (guest must be listening with vsock-listen)
    public func connect() async throws {
        guard !isConnected else { return }

        return try await withCheckedThrowingContinuation { continuation in
            socketDevice.connect(toPort: GUEST_AGENT_PORT) { [weak self] result in
                switch result {
                case .success(let connection):
                    self?.connection = connection
                    self?.handle = FileHandle(
                        fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
                    self?.isConnected = true
                    self?.logger.info(
                        "Connected to guest agent via vsock on port \(GUEST_AGENT_PORT)")
                    continuation.resume()
                case .failure(let error):
                    self?.logger.error("Failed to connect to guest agent: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a ping to check if the guest agent is responding
    public func ping(timeout: TimeInterval = 5.0) async throws -> Bool {
        guard isConnected else {
            return false
        }

        let request = JSONRPCRequest(execute: "guest-ping")
        do {
            let _: EmptyResponse = try await sendCommand(request, timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// Gets network interface information from the guest
    public func getNetworkInterfaces(timeout: TimeInterval = 5.0) async throws
        -> [GuestNetworkInterface]
    {
        guard isConnected else {
            throw QemuGuestAgentError.notConnected
        }

        let request = JSONRPCRequest(execute: "guest-network-get-interfaces")
        let response: [GuestNetworkInterface] = try await sendCommand(request, timeout: timeout)
        return response
    }

    /// Sends a command to the guest agent and waits for a response
    private func sendCommand<T: Codable>(_ request: JSONRPCRequest, timeout: TimeInterval)
        async throws -> T
    {
        guard isConnected, let handle = handle else {
            throw QemuGuestAgentError.notConnected
        }

        // Encode the request
        let encoder = JSONEncoder()
        guard let requestData = try? encoder.encode(request) else {
            throw QemuGuestAgentError.encodingError
        }

        // Add newline delimiter (QEMU guest agent expects line-delimited JSON)
        var dataWithNewline = requestData
        dataWithNewline.append(0x0A)  // \n

        // Send the request
        try handle.write(contentsOf: dataWithNewline)

        logger.debug("sent request", metadata: ["request": "\(request)"])

        // Read response with timeout
        let responseData = try await withTimeout(timeout) {
            try await self.readResponse(from: handle)
        }

        // Decode the response
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(JSONRPCResponse<T>.self, from: responseData) else {
            throw QemuGuestAgentError.decodingError
        }

        logger.debug("received response", metadata: ["response": "\(response)"])

        // Check for errors
        if let error = response.error {
            throw QemuGuestAgentError.agentError(error.desc)
        }

        // Return the result
        guard let result = response.return else {
            throw QemuGuestAgentError.invalidResponse
        }

        return result
    }

    /// Reads a response from the guest agent (blocking, line-delimited)
    private func readResponse(from readHandle: FileHandle) async throws -> Data {
        // Read until we get a newline
        var buffer = Data()
        var readBuffer = [UInt8](repeating: 0, count: 1)

        let fd = readHandle.fileDescriptor

        // Set non-blocking mode
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        while true {
            let bytesRead = read(fd, &readBuffer, 1)

            if bytesRead > 0 {
                buffer.append(readBuffer[0])
                // Check for newline
                if readBuffer[0] == 0x0A {  // \n
                    break
                }
            } else if bytesRead == 0 {
                // EOF
                break
            } else {
                // EAGAIN/EWOULDBLOCK - wait a bit and try again
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                    continue
                } else {
                    throw QemuGuestAgentError.invalidResponse
                }
            }
        }

        // Restore blocking mode
        _ = fcntl(fd, F_SETFL, flags)

        return buffer
    }

    /// Helper to add timeout to async operations
    private func withTimeout<T: Sendable>(
        _ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw QemuGuestAgentError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - JSON-RPC Types (reused from QemuGuestAgent)

/// JSON-RPC request structure
private struct JSONRPCRequest: Codable {
    let execute: String
    let arguments: [String: String]?

    init(execute: String, arguments: [String: String]? = nil) {
        self.execute = execute
        self.arguments = arguments
    }
}

/// JSON-RPC response structure
private struct JSONRPCResponse<T: Codable>: Codable {
    let `return`: T?
    let error: JSONRPCError?
}

/// JSON-RPC error structure
private struct JSONRPCError: Codable {
    let `class`: String
    let desc: String
}

/// Empty response for commands that don't return data
private struct EmptyResponse: Codable {}

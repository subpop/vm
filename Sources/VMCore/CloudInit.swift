import Foundation

/// Errors that can occur during cloud-init ISO generation
public enum CloudInitError: LocalizedError, Sendable {
    case fileCreationFailed(String)
    case isoGenerationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileCreationFailed(let path):
            return "Failed to create cloud-init file at \(path)"
        case .isoGenerationFailed(let message):
            return "Failed to generate cloud-init ISO: \(message)"
        }
    }
}

/// Generates cloud-init NoCloud ISO images for automated VM provisioning.
///
/// Cloud-init is a standard for cloud instance initialization. This generator
/// creates NoCloud data sources as ISO images that can be attached to VMs.
///
/// The generated ISO contains:
/// - `meta-data`: Instance metadata (instance-id, local-hostname, etc.)
/// - `user-data`: Cloud-config YAML for provisioning (users, packages, scripts, etc.)
/// - `network-config`: Optional network configuration
///
/// Usage:
/// ```swift
/// // Create configuration using factory methods
/// let config = CloudInitConfiguration.basicSetup(
///     instanceID: "my-vm-1",
///     hostname: "my-vm",
///     username: "admin",
///     sshKeys: ["ssh-ed25519 AAAA..."]
/// )
///
/// // Generate ISO from configuration
/// let generator = CloudInitISOGenerator(configuration: config)
/// try await generator.generateISO(at: isoURL)
/// ```
public struct CloudInitISOGenerator: Sendable {
    /// The cloud-init configuration.
    public let configuration: CloudInitConfiguration

    /// Creates a new CloudInit ISO generator.
    ///
    /// - Parameter configuration: The cloud-init configuration to use.
    public init(configuration: CloudInitConfiguration) {
        self.configuration = configuration
    }

    /// Generates a cloud-init ISO at the specified path.
    ///
    /// - Parameter path: The path where the ISO will be created.
    /// - Throws: `CloudInitError.isoGenerationFailed` if ISO creation fails.
    public func generateISO(at path: URL) async throws {
        // Create a temporary directory for cloud-init files
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudinit-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write meta-data
        let metaDataPath = tempDir.appendingPathComponent("meta-data")
        try configuration.metaData.write(to: metaDataPath, atomically: true, encoding: .utf8)

        // Write user-data
        let userDataPath = tempDir.appendingPathComponent("user-data")
        try configuration.userData.write(to: userDataPath, atomically: true, encoding: .utf8)

        // Write network-config if present
        if let networkConfig = configuration.networkConfig {
            let networkConfigPath = tempDir.appendingPathComponent("network-config")
            try networkConfig.write(to: networkConfigPath, atomically: true, encoding: .utf8)
        }

        // Ensure parent directory exists
        let parentDir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Remove existing ISO if present
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }

        // Generate ISO using hdiutil
        try await createISO(from: tempDir, to: path)
    }

    /// Creates an ISO image using hdiutil.
    private func createISO(from sourceDir: URL, to outputPath: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-iso",
            "-joliet",
            "-default-volume-name", "CIDATA",
            "-o", outputPath.path,
            sourceDir.path,
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CloudInitError.isoGenerationFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw CloudInitError.isoGenerationFailed(errorString)
        }
    }
}

// MARK: - Convenience Extension

extension CloudInitConfiguration {
    /// Generates a cloud-init ISO from this configuration.
    ///
    /// - Parameter path: The path where the ISO will be created.
    /// - Throws: `VMKitError.cloudInitISOCreationFailed` if ISO creation fails.
    public func generateISO(at path: URL) async throws {
        let generator = CloudInitISOGenerator(configuration: self)
        try await generator.generateISO(at: path)
    }
}

import CryptoKit
import Foundation

/// Errors that can occur during rescue cache operations
public enum RescueCacheError: LocalizedError, Sendable {
    case networkError(String)
    case checksumMismatch(expected: String, actual: String)
    case parseError(String)
    case fileSystemError(String)
    case unsupportedArchitecture(String)
    case conversionError(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .unsupportedArchitecture(let arch):
            return "Unsupported architecture: \(arch)"
        case .conversionError(let message):
            return "Conversion error: \(message)"
        }
    }
}

/// Metadata about a cached rescue image
public struct RescueCacheMetadata: Codable, Sendable {
    public var version: String
    public var sha256: String
    public var arch: String
    public var filename: String
    public var downloadedAt: Date

    public enum CodingKeys: String, CodingKey {
        case version
        case sha256
        case arch
        case filename
        case downloadedAt = "downloaded_at"
    }

    public init(
        version: String, sha256: String, arch: String, filename: String, downloadedAt: Date
    ) {
        self.version = version
        self.sha256 = sha256
        self.arch = arch
        self.filename = filename
        self.downloadedAt = downloadedAt
    }
}

/// Information about an available rescue image
public struct RescueImageInfo: Sendable {
    public let filename: String
    public let sha256: String
    public let version: String
    public let arch: String
    public let downloadURL: URL

    public init(
        filename: String, sha256: String, version: String, arch: String, downloadURL: URL
    ) {
        self.filename = filename
        self.sha256 = sha256
        self.version = version
        self.arch = arch
        self.downloadURL = downloadURL
    }
}

/// Manages downloading, verifying, and caching the Fedora Cloud rescue image
/// Uses Fedora Cloud images which have serial console (hvc0) enabled by default
public final class RescueCache: Sendable {
    /// Fedora version to use
    private static let fedoraVersion = "43"
    private static let fedoraRelease = "1.6"

    /// Base URL for Fedora Cloud images
    private static func baseURL(for arch: String) -> String {
        let fedoraArch = arch == "aarch64" ? "aarch64" : "x86_64"
        return
            "https://download.fedoraproject.org/pub/fedora/linux/releases/\(fedoraVersion)/Cloud/\(fedoraArch)/images/"
    }

    /// The manager for path resolution
    private let manager: Manager

    /// File manager for file operations
    private var fileManager: FileManager { FileManager.default }

    public init(manager: Manager = .shared) {
        self.manager = manager
    }

    // MARK: - Public API

    /// Returns the current system architecture string
    public func currentArchitecture() throws -> String {
        #if arch(arm64)
            return "aarch64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            throw RescueCacheError.unsupportedArchitecture("unknown")
        #endif
    }

    /// Checks if rescue VM is set up and ready
    public func isReady() -> Bool {
        manager.rescueVMExists()
    }

    /// Loads the cached metadata, if available
    public func loadCachedMetadata() throws -> RescueCacheMetadata? {
        let metaPath = manager.rescueMetadataPath
        guard fileManager.fileExists(atPath: metaPath.path) else {
            return nil
        }

        let data = try Data(contentsOf: metaPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RescueCacheMetadata.self, from: data)
    }

    /// Fetches information about the latest available rescue image
    public func fetchLatestImageInfo() async throws -> RescueImageInfo {
        let arch = try currentArchitecture()
        let fedoraArch = arch == "aarch64" ? "aarch64" : "x86_64"

        // Construct the image filename
        let filename =
            "Fedora-Cloud-Base-Generic-\(Self.fedoraVersion)-\(Self.fedoraRelease).\(fedoraArch).qcow2"
        let downloadURL = URL(string: "\(Self.baseURL(for: arch))\(filename)")!

        // Try to get checksum from CHECKSUM file
        let checksumFilename =
            "Fedora-Cloud-\(Self.fedoraVersion)-\(Self.fedoraRelease)-\(fedoraArch)-CHECKSUM"
        let checksumURL = URL(string: "\(Self.baseURL(for: arch))\(checksumFilename)")!

        var sha256 = ""
        do {
            let (data, response) = try await URLSession.shared.data(from: checksumURL)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                let content = String(data: data, encoding: .utf8)
            {
                // Parse checksum file (format: SHA256 (filename) = hash)
                for line in content.components(separatedBy: .newlines) {
                    if line.contains(filename) && line.contains("SHA256") {
                        if let equalsIndex = line.lastIndex(of: "=") {
                            sha256 = String(line[line.index(after: equalsIndex)...])
                                .trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                }
            }
        } catch {
            // Checksum file not available, will skip verification
        }

        return RescueImageInfo(
            filename: filename,
            sha256: sha256,
            version: "\(Self.fedoraVersion)-\(Self.fedoraRelease)",
            arch: arch,
            downloadURL: downloadURL
        )
    }

    /// Checks if a newer version is available compared to the cached one
    public func checkForUpdate() async throws -> (hasUpdate: Bool, latest: RescueImageInfo) {
        let latest = try await fetchLatestImageInfo()

        guard let cached = try loadCachedMetadata() else {
            return (true, latest)
        }

        // Compare versions
        let hasUpdate = latest.version != cached.version
        return (hasUpdate, latest)
    }

    /// Downloads, converts, and sets up the rescue VM
    /// - Parameters:
    ///   - info: Information about the image to download
    ///   - progressHandler: Callback for download progress
    ///   - statusHandler: Callback for status updates (conversion, etc.)
    public func downloadAndSetup(
        _ info: RescueImageInfo,
        progressHandler: (@Sendable (Int64, Int64?) -> Void)? = nil,
        statusHandler: (@Sendable (String) -> Void)? = nil
    ) async throws {
        // Ensure rescue VM directory exists
        let rescueDir = manager.rescueVMDirectory
        if !fileManager.fileExists(atPath: rescueDir.path) {
            try fileManager.createDirectory(at: rescueDir, withIntermediateDirectories: true)
        }

        let qcow2Path = manager.rescueQcow2Path
        let rawPath = manager.rescueImagePath

        // Remove any existing files
        try? fileManager.removeItem(at: qcow2Path)
        try? fileManager.removeItem(at: rawPath)

        // Download qcow2 with progress
        statusHandler?("Downloading Fedora Cloud image...")
        try await downloadFile(
            from: info.downloadURL,
            to: qcow2Path,
            expectedSHA256: info.sha256.isEmpty ? nil : info.sha256,
            progressHandler: progressHandler
        )

        // Convert qcow2 to raw
        statusHandler?("Converting qcow2 to raw format (this may take a moment)...")
        let diskManager = DiskManager.shared
        do {
            try await diskManager.convertQcow2ToRaw(from: qcow2Path, to: rawPath)
        } catch {
            throw RescueCacheError.conversionError(
                "Failed to convert qcow2 to raw: \(error.localizedDescription)")
        }

        // Remove the qcow2 file to save space
        try? fileManager.removeItem(at: qcow2Path)

        // Create cloud-init ISO for auto-login
        statusHandler?("Creating cloud-init configuration...")
        try await createCloudInitISO()

        // Create rescue VM configuration
        statusHandler?("Creating rescue VM configuration...")
        try createRescueVMConfiguration()

        // Save metadata
        let metadata = RescueCacheMetadata(
            version: info.version,
            sha256: info.sha256,
            arch: info.arch,
            filename: info.filename,
            downloadedAt: Date()
        )
        try saveMetadata(metadata)

        statusHandler?("Rescue VM setup complete")
    }

    // MARK: - Private Helpers

    /// Downloads a file with progress reporting and optional SHA256 verification
    private func downloadFile(
        from url: URL,
        to destination: URL,
        expectedSHA256: String?,
        progressHandler: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws {
        let tempPath = destination.appendingPathExtension("download")

        // Remove any existing temp file
        try? fileManager.removeItem(at: tempPath)

        // Download with progress
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw RescueCacheError.networkError(
                "Failed to download: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let expectedLength = httpResponse.expectedContentLength

        // Create output file
        fileManager.createFile(atPath: tempPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempPath)
        defer { try? fileHandle.close() }

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        let bufferSize = 1024 * 1024  // 1MB buffer

        for try await byte in asyncBytes {
            buffer.append(byte)
            downloadedBytes += 1

            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progressHandler?(downloadedBytes, expectedLength > 0 ? expectedLength : nil)
            }
        }

        // Write remaining buffer
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }
        progressHandler?(downloadedBytes, expectedLength > 0 ? expectedLength : nil)

        try fileHandle.close()

        // Verify checksum if provided
        if let expected = expectedSHA256, !expected.isEmpty {
            let actualChecksum = try computeSHA256(of: tempPath)
            guard actualChecksum.lowercased() == expected.lowercased() else {
                try? fileManager.removeItem(at: tempPath)
                throw RescueCacheError.checksumMismatch(
                    expected: expected, actual: actualChecksum)
            }
        }

        // Move to final location
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: tempPath, to: destination)
    }

    /// Creates a cloud-init ISO for the rescue environment using the standard CloudInitConfiguration
    private func createCloudInitISO() async throws {
        let config = try CloudInitConfiguration.rescueSetup()
        let isoPath = manager.rescueCloudInitPath
        try await config.generateISO(at: isoPath)
    }

    /// Creates the rescue VM configuration
    private func createRescueVMConfiguration() throws {
        // Get disk size
        let diskSize = try DiskManager.shared.getDiskSize(at: manager.rescueImagePath)

        // Create rescue VM configuration using the factory method
        let config = VMConfiguration.create(
            name: Manager.rescueVMName,
            cpuCount: min(ProcessInfo.processInfo.activeProcessorCount, 4),
            memorySize: 4 * 1024 * 1024 * 1024,  // 4GB RAM
            diskSize: diskSize,
            isoPath: nil
        )

        // Save the configuration
        let configPath = manager.configPath(for: Manager.rescueVMName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: configPath)
    }

    /// Computes the SHA256 hash of a file
    private func computeSHA256(of url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024  // 1MB

        while let data = try fileHandle.read(upToCount: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Saves metadata to the cache directory
    private func saveMetadata(_ metadata: RescueCacheMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(metadata)
        try data.write(to: manager.rescueMetadataPath)
    }
}

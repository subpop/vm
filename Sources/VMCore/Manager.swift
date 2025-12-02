import Foundation

/// Errors that can occur during VM management operations
public enum ManagerError: LocalizedError, Sendable {
    case vmAlreadyExists(String)
    case vmNotFound(String)
    case configurationError(String)
    case fileSystemError(String)
    case invalidVMName(String)

    public var errorDescription: String? {
        switch self {
        case .vmAlreadyExists(let name):
            return "VM '\(name)' already exists"
        case .vmNotFound(let name):
            return "VM '\(name)' not found"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .invalidVMName(let name):
            return
                "Invalid VM name '\(name)': names must be alphanumeric with dashes or underscores"
        }
    }
}

/// Manages VM storage and configuration
public final class Manager: Sendable {
    /// Base directory for all VMs (~/.vm)
    public let baseDirectory: URL

    /// Shared instance using default directory
    public static let shared = Manager()

    /// File manager for file operations
    private var fileManager: FileManager { FileManager.default }

    /// Creates a JSON encoder for configuration files
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Creates a JSON decoder for configuration files
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            self.baseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vm")
        }
    }

    /// Ensures the base directory exists
    public func ensureBaseDirectoryExists() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    /// Returns the directory for a specific VM
    public func vmDirectory(for name: String) -> URL {
        baseDirectory.appendingPathComponent(name)
    }

    /// Returns the configuration file path for a VM
    public func configPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("config.json")
    }

    /// Returns the disk image path for a VM
    public func diskPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("disk.img")
    }

    /// Returns the EFI variable store path for a VM
    public func nvramPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("nvram.bin")
    }

    /// Returns the PID file path for a VM
    public func pidPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("vm.pid")
    }

    /// Returns the console socket path for a VM
    public func consoleSocketPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("console.sock")
    }

    /// Returns the network info file path for a VM
    public func networkInfoPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("network-info.json")
    }

    /// Returns the cloud-init ISO path for a VM
    public func cloudInitISOPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("cloud-init.iso")
    }

    /// Returns the log file path for a VM
    public func logPath(for name: String) -> URL {
        vmDirectory(for: name).appendingPathComponent("vm.log")
    }

    /// Validates a VM name
    public func validateVMName(_ name: String) throws {
        let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !name.isEmpty,
            name.unicodeScalars.allSatisfy({ validCharacters.contains($0) }),
            !name.hasPrefix("-"),
            !name.hasPrefix("_")
        else {
            throw ManagerError.invalidVMName(name)
        }
    }

    /// Checks if a VM exists
    public func vmExists(_ name: String) -> Bool {
        fileManager.fileExists(atPath: configPath(for: name).path)
    }

    /// Creates a new VM directory and saves its configuration
    public func createVM(_ config: VMConfiguration) throws {
        try validateVMName(config.name)

        let vmDir = vmDirectory(for: config.name)

        if fileManager.fileExists(atPath: vmDir.path) {
            throw ManagerError.vmAlreadyExists(config.name)
        }

        try ensureBaseDirectoryExists()
        try fileManager.createDirectory(at: vmDir, withIntermediateDirectories: true)
        try saveConfiguration(config)
    }

    /// Saves a VM configuration to disk
    public func saveConfiguration(_ config: VMConfiguration) throws {
        var updatedConfig = config
        updatedConfig.modifiedAt = Date()

        let data = try makeEncoder().encode(updatedConfig)
        try data.write(to: configPath(for: config.name))
    }

    /// Loads a VM configuration from disk
    public func loadConfiguration(for name: String) throws -> VMConfiguration {
        let path = configPath(for: name)

        guard fileManager.fileExists(atPath: path.path) else {
            throw ManagerError.vmNotFound(name)
        }

        let data = try Data(contentsOf: path)
        return try makeDecoder().decode(VMConfiguration.self, from: data)
    }

    /// Lists all VM names
    public func listVMs() throws -> [String] {
        try ensureBaseDirectoryExists()

        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return contents.compactMap { url -> String? in
            guard fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path)
            else {
                return nil
            }
            return url.lastPathComponent
        }.sorted()
    }

    /// Deletes a VM and all its files
    public func deleteVM(_ name: String) throws {
        let vmDir = vmDirectory(for: name)

        guard fileManager.fileExists(atPath: vmDir.path) else {
            throw ManagerError.vmNotFound(name)
        }

        // Check if VM is running
        if getRunningPID(for: name) != nil {
            throw ManagerError.configurationError(
                "VM '\(name)' is currently running. Stop it first.")
        }

        try fileManager.removeItem(at: vmDir)
    }

    /// Saves runtime info (PID) for a running VM
    public func saveRuntimeInfo(_ info: VMRuntimeInfo, for name: String) throws {
        let data = try makeEncoder().encode(info)
        try data.write(to: pidPath(for: name))
    }

    /// Loads runtime info for a VM
    public func loadRuntimeInfo(for name: String) throws -> VMRuntimeInfo? {
        let path = pidPath(for: name)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }

        let data = try Data(contentsOf: path)
        return try makeDecoder().decode(VMRuntimeInfo.self, from: data)
    }

    /// Removes the PID file for a VM
    public func clearRuntimeInfo(for name: String) throws {
        let path = pidPath(for: name)
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
    }

    /// Gets the PID of a running VM, verifying the process exists
    public func getRunningPID(for name: String) -> Int32? {
        guard let info = try? loadRuntimeInfo(for: name) else {
            return nil
        }

        // Check if process is actually running
        if kill(info.pid, 0) == 0 {
            return info.pid
        } else {
            // Process not running, clean up stale PID file
            try? clearRuntimeInfo(for: name)
            return nil
        }
    }

    /// Checks if a VM is running
    public func isVMRunning(_ name: String) -> Bool {
        getRunningPID(for: name) != nil
    }

    /// Saves network info for a VM
    public func saveNetworkInfo(_ info: VMNetworkInfo, for name: String) throws {
        let data = try makeEncoder().encode(info)
        try data.write(to: networkInfoPath(for: name))
    }

    /// Loads network info for a VM
    public func loadNetworkInfo(for name: String) throws -> VMNetworkInfo? {
        let path = networkInfoPath(for: name)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }

        let data = try Data(contentsOf: path)
        return try makeDecoder().decode(VMNetworkInfo.self, from: data)
    }

    /// Clears network info for a VM
    public func clearNetworkInfo(for name: String) throws {
        let path = networkInfoPath(for: name)
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
    }
}

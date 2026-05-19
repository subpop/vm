import Foundation

/// Errors that can occur during snapshot operations
public enum SnapshotError: LocalizedError, Sendable {
    case snapshotNotFound(String)
    case snapshotExists(String)
    case diskNotFound(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .snapshotNotFound(let id):
            return "Snapshot not found: \(id)"
        case .snapshotExists(let id):
            return "Snapshot already exists: \(id)"
        case .diskNotFound(let path):
            return "Disk image not found: \(path)"
        case .operationFailed(let message):
            return message
        }
    }
}

/// A single VM snapshot entry in the manifest
public struct VMSnapshot: Codable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var diskSize: UInt64
    public var cloneMethod: CloneMethod
    public var description: String?
    public var hasNVRAM: Bool

    public enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case diskSize = "disk_size"
        case cloneMethod = "clone_method"
        case description
        case hasNVRAM = "has_nvram"
    }
}

/// Snapshot manifest stored in snapshots.json
public struct SnapshotManifest: Codable, Sendable {
    public var snapshots: [VMSnapshot]

    public init(snapshots: [VMSnapshot] = []) {
        self.snapshots = snapshots
    }
}

/// Detailed snapshot info for listing
public struct VMSnapshotInfo: Sendable {
    public var snapshot: VMSnapshot
    public var allocatedBytes: UInt64?
}

/// Manages VM snapshots using APFS file clones
public final class SnapshotManager: Sendable {
    private var fileManager: FileManager { FileManager.default }

    public static let shared = SnapshotManager()

    private let manager: Manager
    private let diskManager: DiskManager

    public init(manager: Manager = .shared, diskManager: DiskManager = .shared) {
        self.manager = manager
        self.diskManager = diskManager
    }

    private static let diskFileName = "disk.img"
    private static let nvramFileName = "nvram.bin"

    /// Generates a default snapshot ID from the current time
    public static func defaultSnapshotID() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Creates a snapshot of a stopped VM's disk and NVRAM
    @discardableResult
    public func createSnapshot(
        vmName: String,
        id: String? = nil,
        description: String? = nil
    ) throws -> VMSnapshot {
        guard manager.vmExists(vmName) else {
            throw ManagerError.vmNotFound(vmName)
        }
        try manager.requireVMStopped(vmName)

        let snapshotID = id ?? Self.defaultSnapshotID()
        try manager.validateVMName(snapshotID)

        var manifest = try loadManifest(for: vmName)
        if manifest.snapshots.contains(where: { $0.id == snapshotID }) {
            throw SnapshotError.snapshotExists(snapshotID)
        }

        let diskSource = try manager.resolvedDiskURL(for: vmName)
        guard fileManager.fileExists(atPath: diskSource.path) else {
            throw SnapshotError.diskNotFound(diskSource.path)
        }

        let snapshotDir = manager.snapshotDirectory(for: vmName, snapshotID: snapshotID)
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let diskDest = snapshotDir.appendingPathComponent(Self.diskFileName)
        let diskMethod = try diskManager.cloneFile(from: diskSource, to: diskDest)

        var hasNVRAM = false
        let nvramSource = manager.nvramPath(for: vmName)
        if fileManager.fileExists(atPath: nvramSource.path) {
            let nvramDest = snapshotDir.appendingPathComponent(Self.nvramFileName)
            _ = try diskManager.cloneFile(from: nvramSource, to: nvramDest)
            hasNVRAM = true
        }

        let config = try manager.loadConfiguration(for: vmName)
        let entry = VMSnapshot(
            id: snapshotID,
            createdAt: Date(),
            diskSize: config.diskSize,
            cloneMethod: diskMethod,
            description: description,
            hasNVRAM: hasNVRAM
        )

        manifest.snapshots.append(entry)
        try saveManifest(manifest, for: vmName)

        return entry
    }

    /// Lists all snapshots for a VM
    public func listSnapshots(vmName: String) throws -> [VMSnapshotInfo] {
        guard manager.vmExists(vmName) else {
            throw ManagerError.vmNotFound(vmName)
        }

        let manifest = try loadManifest(for: vmName)
        return manifest.snapshots.map { snapshot in
            let snapshotDir = manager.snapshotDirectory(for: vmName, snapshotID: snapshot.id)
            let diskPath = snapshotDir.appendingPathComponent(Self.diskFileName)
            let allocated = try? diskManager.getAllocatedSize(at: diskPath)
            return VMSnapshotInfo(snapshot: snapshot, allocatedBytes: allocated)
        }
    }

    /// Deletes a snapshot
    public func deleteSnapshot(vmName: String, id: String) throws {
        guard manager.vmExists(vmName) else {
            throw ManagerError.vmNotFound(vmName)
        }

        var manifest = try loadManifest(for: vmName)
        guard let index = manifest.snapshots.firstIndex(where: { $0.id == id }) else {
            throw SnapshotError.snapshotNotFound(id)
        }

        let snapshotDir = manager.snapshotDirectory(for: vmName, snapshotID: id)
        if fileManager.fileExists(atPath: snapshotDir.path) {
            try fileManager.removeItem(at: snapshotDir)
        }

        manifest.snapshots.remove(at: index)
        try saveManifest(manifest, for: vmName)
    }

    /// Restores a VM from a snapshot
    public func restoreSnapshot(vmName: String, id: String, createBackup: Bool = true) throws {
        guard manager.vmExists(vmName) else {
            throw ManagerError.vmNotFound(vmName)
        }
        try manager.requireVMStopped(vmName)

        let manifest = try loadManifest(for: vmName)
        guard let snapshot = manifest.snapshots.first(where: { $0.id == id }) else {
            throw SnapshotError.snapshotNotFound(id)
        }

        let snapshotDir = manager.snapshotDirectory(for: vmName, snapshotID: id)
        let snapshotDisk = snapshotDir.appendingPathComponent(Self.diskFileName)
        guard fileManager.fileExists(atPath: snapshotDisk.path) else {
            throw SnapshotError.snapshotNotFound(id)
        }

        if createBackup {
            let backupID = "pre-restore-\(Self.defaultSnapshotID())"
            _ = try createSnapshot(
                vmName: vmName, id: backupID, description: "Auto-backup before restore")
        }

        let diskDest = try manager.resolvedDiskURL(for: vmName)
        let nvramDest = manager.nvramPath(for: vmName)

        try replaceFile(
            from: snapshotDisk,
            to: diskDest
        )

        let snapshotNVRAM = snapshotDir.appendingPathComponent(Self.nvramFileName)
        if snapshot.hasNVRAM, fileManager.fileExists(atPath: snapshotNVRAM.path) {
            try replaceFile(from: snapshotNVRAM, to: nvramDest)
        }

        var config = try manager.loadConfiguration(for: vmName)
        config.diskSize = snapshot.diskSize
        try manager.saveConfiguration(config)
    }

    /// Returns the number of snapshots for a VM
    public func snapshotCount(vmName: String) throws -> Int {
        try loadManifest(for: vmName).snapshots.count
    }

    // MARK: - Private

    private func loadManifest(for vmName: String) throws -> SnapshotManifest {
        let path = manager.snapshotManifestPath(for: vmName)
        guard fileManager.fileExists(atPath: path.path) else {
            return SnapshotManifest()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: path)
        return try decoder.decode(SnapshotManifest.self, from: data)
    }

    private func saveManifest(_ manifest: SnapshotManifest, for vmName: String) throws {
        let snapshotsDir = manager.snapshotsDirectory(for: vmName)
        if !fileManager.fileExists(atPath: snapshotsDir.path) {
            try fileManager.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(manifest)
        try data.write(to: manager.snapshotManifestPath(for: vmName))
    }

    private func replaceFile(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let parentDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        _ = try diskManager.cloneFile(from: source, to: destination)
    }
}

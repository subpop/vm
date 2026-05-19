import ArgumentParser
import Foundation
import VMCore

// MARK: - Snapshot Command Group

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Manage VM snapshots",
        discussion: """
            Create and manage point-in-time snapshots of a VM's disk and NVRAM.
            Snapshots use APFS copy-on-write clones when available for space efficiency.

            The VM must be stopped before creating, restoring, or deleting snapshots.

            Examples:
              vm snapshot create ubuntu
              vm snapshot create ubuntu before-upgrade --description "Before dist-upgrade"
              vm snapshot list ubuntu
              vm snapshot restore ubuntu before-upgrade
              vm snapshot delete ubuntu before-upgrade
            """,
        subcommands: [
            SnapshotCreate.self,
            SnapshotList.self,
            SnapshotRestore.self,
            SnapshotDelete.self,
        ]
    )
}

// MARK: - Create

struct SnapshotCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a snapshot of a stopped VM"
    )

    @Argument(help: "Name of the virtual machine", completion: VMNameCompletion.kind)
    var vmName: String

    @Argument(help: "Snapshot name (defaults to timestamp)")
    var snapshotName: String?

    @Option(name: .long, help: "Description for this snapshot")
    var description: String?

    mutating func run() async throws {
        let snapshotManager = SnapshotManager.shared
        let diskManager = DiskManager.shared

        let snapshot = try snapshotManager.createSnapshot(
            vmName: vmName,
            id: snapshotName,
            description: description
        )

        let methodLabel = snapshot.cloneMethod == .apfs ? "APFS clone" : "full copy"
        print("Created snapshot '\(snapshot.id)' for VM '\(vmName)'")
        print("  Disk: \(diskManager.formatSize(snapshot.diskSize))")
        if let allocated = try? diskManager.getAllocatedSize(
            at: Manager.shared.snapshotDirectory(for: vmName, snapshotID: snapshot.id)
                .appendingPathComponent("disk.img")
        ) {
            print("  Allocated: \(diskManager.formatSize(allocated))")
        }
        print("  Method: \(methodLabel)")
        if !snapshot.hasNVRAM {
            print("  Note: No NVRAM file found (EFI state not captured)")
        }
    }
}

// MARK: - List

private struct SnapshotListItem: Codable {
    let id: String
    let createdAt: Date
    let diskSizeBytes: UInt64
    let allocatedBytes: UInt64?
    let cloneMethod: String
    let description: String?
    let hasNVRAM: Bool
}

struct SnapshotList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List snapshots for a virtual machine"
    )

    @Argument(help: "Name of the virtual machine", completion: VMNameCompletion.kind)
    var vmName: String

    @Option(help: "Output format")
    var format: OutputFormat = .text

    mutating func run() async throws {
        let snapshotManager = SnapshotManager.shared
        let diskManager = DiskManager.shared
        let snapshots = try snapshotManager.listSnapshots(vmName: vmName)

        switch format {
        case .text:
            if snapshots.isEmpty {
                print("No snapshots for VM '\(vmName)'")
                return
            }

            var rows: [[String]] = []
            rows.append(["NAME", "CREATED", "DISK SIZE", "ALLOCATED", "METHOD"])

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]

            for info in snapshots {
                let method = info.snapshot.cloneMethod == .apfs ? "apfs" : "copy"
                let allocated = info.allocatedBytes.map { diskManager.formatSize($0) } ?? "-"
                rows.append([
                    info.snapshot.id,
                    formatter.string(from: info.snapshot.createdAt),
                    diskManager.formatSize(info.snapshot.diskSize),
                    allocated,
                    method,
                ])
            }

            let table = TableOutput(rows: rows)
            print(table.format())

        case .json:
            let items = snapshots.map { info in
                SnapshotListItem(
                    id: info.snapshot.id,
                    createdAt: info.snapshot.createdAt,
                    diskSizeBytes: info.snapshot.diskSize,
                    allocatedBytes: info.allocatedBytes,
                    cloneMethod: info.snapshot.cloneMethod.rawValue,
                    description: info.snapshot.description,
                    hasNVRAM: info.snapshot.hasNVRAM
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            print(String(data: data, encoding: .utf8)!)
        }
    }
}

// MARK: - Restore

struct SnapshotRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a VM from a snapshot",
        discussion: """
            Restores the VM's disk and NVRAM from a snapshot. By default, a
            pre-restore backup snapshot is created automatically.

            Examples:
              vm snapshot restore ubuntu before-upgrade
              vm snapshot restore ubuntu before-upgrade --no-backup
            """
    )

    @Argument(help: "Name of the virtual machine", completion: VMNameCompletion.kind)
    var vmName: String

    @Argument(help: "Snapshot name to restore")
    var snapshotName: String

    @Flag(name: .long, help: "Skip creating a pre-restore backup snapshot")
    var noBackup: Bool = false

    mutating func run() async throws {
        let snapshotManager = SnapshotManager.shared

        print("Restoring VM '\(vmName)' from snapshot '\(snapshotName)'...")
        if !noBackup {
            print("Creating pre-restore backup...")
        }

        try snapshotManager.restoreSnapshot(
            vmName: vmName,
            id: snapshotName,
            createBackup: !noBackup
        )

        print("✓ VM '\(vmName)' restored from snapshot '\(snapshotName)'")
    }
}

// MARK: - Delete

struct SnapshotDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a snapshot",
        discussion: """
            Deletes a snapshot and frees its disk space. The VM must be stopped.

            Examples:
              vm snapshot delete ubuntu before-upgrade
              vm snapshot delete ubuntu before-upgrade --force
            """
    )

    @Argument(help: "Name of the virtual machine", completion: VMNameCompletion.kind)
    var vmName: String

    @Argument(help: "Snapshot name to delete")
    var snapshotName: String

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force: Bool = false

    mutating func run() async throws {
        let snapshotManager = SnapshotManager.shared
        let diskManager = DiskManager.shared

        if !force {
            let snapshots = try snapshotManager.listSnapshots(vmName: vmName)
            guard let info = snapshots.first(where: { $0.snapshot.id == snapshotName }) else {
                throw SnapshotError.snapshotNotFound(snapshotName)
            }

            print("About to delete snapshot '\(snapshotName)' for VM '\(vmName)':")
            print("  Created: \(info.snapshot.createdAt)")
            print("  Disk:    \(diskManager.formatSize(info.snapshot.diskSize))")
            print("")
            print("Type '\(snapshotName)' to confirm deletion: ", terminator: "")

            guard let input = readLine(), input == snapshotName else {
                print("Deletion cancelled")
                return
            }
        }

        try snapshotManager.deleteSnapshot(vmName: vmName, id: snapshotName)
        print("✓ Snapshot '\(snapshotName)' deleted")
    }
}

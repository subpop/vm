import Foundation
import Testing

@testable import VMCore

@Suite("Snapshot Tests")
struct SnapshotTests {

    private func makeTempVM() throws -> (Manager, SnapshotManager, String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-snapshot-test-\(UUID().uuidString)")
        let manager = Manager(baseDirectory: tempDir)
        let snapshotManager = SnapshotManager(manager: manager)
        let vmName = "testvm"

        try manager.ensureBaseDirectoryExists()
        let config = VMConfiguration.create(name: vmName, diskSize: 1024 * 1024)
        try manager.createVM(config)

        let diskPath = manager.diskPath(for: vmName)
        try DiskManager.shared.createDiskImage(at: diskPath, size: 1024 * 1024)

        let nvramPath = manager.nvramPath(for: vmName)
        FileManager.default.createFile(atPath: nvramPath.path, contents: Data([0x01, 0x02]), attributes: nil)

        return (manager, snapshotManager, vmName)
    }

    @Test("create and list snapshot")
    func createAndList() throws {
        let (manager, snapshotManager, vmName) = try makeTempVM()

        let snapshot = try snapshotManager.createSnapshot(
            vmName: vmName,
            id: "snap1",
            description: "test snapshot"
        )

        #expect(snapshot.id == "snap1")
        #expect(snapshot.description == "test snapshot")
        #expect(snapshot.hasNVRAM)

        let listed = try snapshotManager.listSnapshots(vmName: vmName)
        #expect(listed.count == 1)
        #expect(listed[0].snapshot.id == "snap1")

        let snapshotDir = manager.snapshotDirectory(for: vmName, snapshotID: "snap1")
        #expect(FileManager.default.fileExists(atPath: snapshotDir.appendingPathComponent("disk.img").path))
        #expect(FileManager.default.fileExists(atPath: snapshotDir.appendingPathComponent("nvram.bin").path))

        try FileManager.default.removeItem(at: manager.baseDirectory)
    }

    @Test("duplicate snapshot ID is rejected")
    func duplicateSnapshotRejected() throws {
        let (manager, snapshotManager, vmName) = try makeTempVM()

        _ = try snapshotManager.createSnapshot(vmName: vmName, id: "snap1")
        #expect(throws: SnapshotError.self) {
            try snapshotManager.createSnapshot(vmName: vmName, id: "snap1")
        }

        try FileManager.default.removeItem(at: manager.baseDirectory)
    }

    @Test("restore replaces disk content")
    func restoreSnapshot() throws {
        let (manager, snapshotManager, vmName) = try makeTempVM()
        let diskPath = manager.diskPath(for: vmName)

        _ = try snapshotManager.createSnapshot(vmName: vmName, id: "baseline")

        // Modify live disk
        let handle = try FileHandle(forWritingTo: diskPath)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 512))
        try handle.close()

        try snapshotManager.restoreSnapshot(vmName: vmName, id: "baseline", createBackup: false)

        let readHandle = try FileHandle(forReadingFrom: diskPath)
        let data = try readHandle.read(upToCount: 512)
        try readHandle.close()

        // Restored disk should match pre-modification sparse zeros
        #expect(data == Data(repeating: 0, count: 512))

        try FileManager.default.removeItem(at: manager.baseDirectory)
    }

    @Test("delete snapshot removes files")
    func deleteSnapshot() throws {
        let (manager, snapshotManager, vmName) = try makeTempVM()

        _ = try snapshotManager.createSnapshot(vmName: vmName, id: "snap1")
        try snapshotManager.deleteSnapshot(vmName: vmName, id: "snap1")

        let listed = try snapshotManager.listSnapshots(vmName: vmName)
        #expect(listed.isEmpty)

        let snapshotDir = manager.snapshotDirectory(for: vmName, snapshotID: "snap1")
        #expect(!FileManager.default.fileExists(atPath: snapshotDir.path))

        try FileManager.default.removeItem(at: manager.baseDirectory)
    }

    @Test("cloneFile falls back to copy on cross-volume or unsupported FS")
    func cloneFileWorks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-clone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let source = tempDir.appendingPathComponent("source.bin")
        let dest = tempDir.appendingPathComponent("dest.bin")
        FileManager.default.createFile(atPath: source.path, contents: Data([1, 2, 3]), attributes: nil)

        let method = try DiskManager.shared.cloneFile(from: source, to: dest)
        #expect(method == .apfs || method == .copy)
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let destData = try Data(contentsOf: dest)
        #expect(destData == Data([1, 2, 3]))

        try FileManager.default.removeItem(at: tempDir)
    }
}

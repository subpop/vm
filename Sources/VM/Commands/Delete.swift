import ArgumentParser
import Foundation
import VMCore

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a virtual machine",
        discussion: """
            Deletes a virtual machine and all its associated files.
            
            The VM must be stopped before it can be deleted. This operation
            cannot be undone - the disk image and all configuration will be
            permanently removed.
            
            Examples:
              vm delete ubuntu
              vm delete ubuntu --force  # Skip confirmation
            """
    )
    
    @Argument(help: "Name of the virtual machine to delete")
    var name: String
    
    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force: Bool = false
    
    mutating func run() async throws {
        let vmManager = Manager.shared
        let diskManager = DiskManager.shared
        
        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }
        
        // Check if VM is running
        if vmManager.isVMRunning(name) {
            throw ManagerError.configurationError("VM '\(name)' is currently running. Stop it first with 'vm stop \(name)'")
        }
        
        // Get VM info for confirmation
        let config = try vmManager.loadConfiguration(for: name)
        let vmDir = vmManager.vmDirectory(for: name)
        
        // Calculate total size synchronously
        let totalSize = calculateDirectorySize(at: vmDir)
        
        if !force {
            print("About to delete VM '\(name)':")
            print("  Location: \(vmDir.path)")
            print("  Disk:     \(diskManager.formatSize(config.diskSize))")
            print("  Total:    \(diskManager.formatSize(totalSize))")
            print("")
            print("This action cannot be undone")
            print("Type '\(name)' to confirm deletion: ", terminator: "")
            
            guard let input = readLine(), input == name else {
                print("Deletion cancelled")
                return
            }
        }
        
        print("Deleting VM '\(name)'...")
        try vmManager.deleteVM(name)
        print("✓ VM '\(name)' deleted successfully")
    }
    
    /// Calculate directory size synchronously to avoid async context issues
    private func calculateDirectorySize(at url: URL) -> UInt64 {
        var totalSize: UInt64 = 0
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += UInt64(size)
            }
        }
        
        return totalSize
    }
}

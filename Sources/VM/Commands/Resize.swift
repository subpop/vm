import ArgumentParser
import Foundation
import VMCore

struct Resize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resize the disk image of a virtual machine",
        discussion: """
            Resizes the disk image to the specified size. The VM must be stopped
            before resizing. Only expanding the disk is supported; shrinking is not.

            After resizing the disk image, you will need to expand the filesystem
            inside the guest OS to use the additional space.

            Examples:
              vm resize debian --size 256G
            """
    )

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Option(name: .long, help: "New disk size (e.g., 128G, 256G, 512G)")
    var size: String

    mutating func validate() throws {
        // Validate that the size can be parsed
        let diskManager = DiskManager.shared
        let sizeBytes = try diskManager.parseSize(size)
        guard sizeBytes >= 1024 * 1024 * 1024 else {  // At least 1GB
            throw ValidationError("Disk size must be at least 1GB")
        }
    }

    mutating func run() async throws {
        let vmManager = Manager.shared
        let diskManager = DiskManager.shared

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        // Check if VM is running
        if vmManager.isVMRunning(name) {
            throw ManagerError.configurationError(
                "VM '\(name)' is currently running. Stop it first with: vm stop \(name)")
        }

        // Load current configuration
        var config = try vmManager.loadConfiguration(for: name)
        let currentSize = config.diskSize

        // Parse new size
        let newSizeBytes = try diskManager.parseSize(size)

        // Check if resize is needed
        if newSizeBytes == currentSize {
            print("Disk is already \(diskManager.formatSize(currentSize)), no changes needed")
            return
        }

        if newSizeBytes < currentSize {
            throw DiskError.resizeFailed(
                "Cannot shrink disk from \(diskManager.formatSize(currentSize)) to \(diskManager.formatSize(newSizeBytes)). Only expansion is supported."
            )
        }

        // Get disk path
        let diskPath = vmManager.diskPath(for: name)

        print("Resizing disk for VM '\(name)'...")
        print("  Current size: \(diskManager.formatSize(currentSize))")
        print("  New size: \(diskManager.formatSize(newSizeBytes))")

        // Resize the disk image
        try diskManager.resizeDiskImage(at: diskPath, to: newSizeBytes)

        // Update configuration
        config.diskSize = newSizeBytes
        try vmManager.saveConfiguration(config)

        print("✓ Disk resized successfully")
        print("")
        print("Note: You will need to expand the filesystem inside the guest OS")
        print("to use the additional space. Common commands:")
        print("  - For ext4: sudo resize2fs /dev/vda2")
        print("  - For LVM: sudo pvresize /dev/vda2 && sudo lvextend -l +100%FREE /dev/mapper/...")
        print("  - For cloud images: sudo growpart /dev/vda 2 && sudo resize2fs /dev/vda2")
    }
}

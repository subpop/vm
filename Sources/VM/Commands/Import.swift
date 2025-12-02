import ArgumentParser
import Foundation
import VMCore

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import an existing disk image as a new VM",
        discussion: """
            Creates a new virtual machine using an existing disk image.

            By default, the disk image is used in place (not copied). Use --copy
            to create a copy of the disk image in the VM directory.

            Use --size with --copy to resize the disk during import. The new size
            must be larger than or equal to the original disk size.

            The disk image should be a raw disk image. QCOW2 and other formats
            are not supported.

            Examples:
              vm import ubuntu --disk ~/VMs/ubuntu.img
              vm import debian --disk debian.raw --copy
              vm import arch --disk arch.img --cpus 4 --memory 8G
              vm import ubuntu --disk ubuntu.img --copy --size 128G
            """
    )

    @Argument(help: "Name for the new virtual machine")
    var name: String

    @Option(name: .long, help: "Path to the disk image to import")
    var disk: String

    @Flag(name: .long, help: "Copy the disk image instead of using it in place")
    var copy: Bool = false

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    @Option(name: .long, help: "Memory size (e.g., 4G, 8G, 16G)")
    var memory: String = "4G"

    @Option(name: .long, help: "Resize disk to this size (e.g., 64G, 128G) - requires --copy")
    var size: String?

    mutating func validate() throws {
        // Validate CPU count
        let maxCPUs = ProcessInfo.processInfo.processorCount
        guard cpus >= 1 && cpus <= maxCPUs else {
            throw ValidationError("CPU count must be between 1 and \(maxCPUs)")
        }

        // Validate memory
        let diskManager = DiskManager.shared
        let memoryBytes = try diskManager.parseSize(memory)
        let minMemory: UInt64 = 512 * 1024 * 1024  // 512MB
        let maxMemory = UInt64(ProcessInfo.processInfo.physicalMemory)
        guard memoryBytes >= minMemory && memoryBytes <= maxMemory else {
            throw ValidationError(
                "Memory must be between 512MB and \(diskManager.formatSize(maxMemory))")
        }

        // Validate --size requires --copy
        if size != nil && !copy {
            throw ValidationError("--size requires --copy (cannot resize disk in-place)")
        }

        // Validate size format if provided
        if let sizeStr = size {
            _ = try diskManager.parseSize(sizeStr)
        }
    }

    mutating func run() async throws {
        let vmManager = Manager.shared
        let diskManager = DiskManager.shared

        // Validate VM name
        try vmManager.validateVMName(name)

        // Check if VM already exists
        if vmManager.vmExists(name) {
            throw ManagerError.vmAlreadyExists(name)
        }

        // Validate disk image exists
        let sourceURL = try diskManager.validateFileExists(at: disk)

        // Get disk size
        let diskSize = try diskManager.getDiskSize(at: sourceURL)

        // Parse target size if provided
        let targetSize: UInt64
        if let sizeStr = size {
            targetSize = try diskManager.parseSize(sizeStr)
        } else {
            targetSize = diskSize
        }

        // Parse memory
        let memoryBytes = try diskManager.parseSize(memory)

        print("Importing disk image as VM '\(name)'...")
        print("  Source: \(sourceURL.path)")
        print("  Source Size: \(diskManager.formatSize(diskSize))")
        if size != nil {
            print("  Target Size: \(diskManager.formatSize(targetSize))")
        }
        print("  CPUs: \(cpus)")
        print("  Memory: \(diskManager.formatSize(memoryBytes))")
        print("  Mode: \(copy ? "Copy" : "In-place")")

        // Create configuration with target size
        var config = VMConfiguration.create(
            name: name,
            cpuCount: cpus,
            memorySize: memoryBytes,
            diskSize: targetSize,
            isoPath: nil
        )

        // Ensure base directory exists
        try vmManager.ensureBaseDirectoryExists()

        // Create VM directory
        let vmDir = vmManager.vmDirectory(for: name)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)

        if copy {
            // Copy disk image to VM directory
            let destPath = vmManager.diskPath(for: name)
            print("Copying disk image...")
            try diskManager.copyDiskImage(from: sourceURL, to: destPath)

            // Resize if requested
            if targetSize > diskSize {
                print("Resizing disk to \(diskManager.formatSize(targetSize))...")
                try diskManager.resizeDiskImage(at: destPath, to: targetSize)
            }

            config.diskImagePath = "disk.img"
        } else {
            // Use disk image in place (store absolute path)
            config.diskImagePath = sourceURL.path

            // Create a symlink in the VM directory for convenience
            let linkPath = vmManager.diskPath(for: name)
            try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: sourceURL)
        }

        // Generate cloud-init ISO for automatic guest agent configuration
        let sshKeys = readLocalSSHKeys()
        let cloudInitPath = vmManager.cloudInitISOPath(for: name)
        let cloudInitConfiguation = try CloudInitConfiguration.withDefaultPackagesAndCommands(
            instanceID: name,
            hostname: name,
            username: ProcessInfo.processInfo.userName,
            sshKeys: sshKeys
        )
        let cloudInitISOGenerator = CloudInitISOGenerator(configuration: cloudInitConfiguation)
        try await cloudInitISOGenerator.generateISO(at: cloudInitPath)

        // Save configuration
        try vmManager.saveConfiguration(config)

        print("✓ VM '\(name)' imported successfully")
        print("  Location: \(vmDir.path)")
        print("\nTo start the VM, run:")
        print("  vm start \(name)")
    }
}

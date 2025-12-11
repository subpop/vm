import ArgumentParser
import Foundation
import VMCore

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new virtual machine",
        discussion: """
            Creates a new Linux virtual machine with the specified configuration.
            If an ISO is provided with --iso, the VM will boot from it for installation.

            Examples:
              vm create ubuntu-server --iso ~/Downloads/ubuntu-22.04.iso
              vm create debian --iso debian.iso --disk-size 128G --cpus 4 --memory 8G
              vm create arch --disk-size 32G
            """
    )

    @Argument(help: "Name for the new virtual machine")
    var name: String

    @Option(name: .long, help: "Path to an ISO image for installation")
    var iso: String?

    @Option(name: .long, help: "Disk size (e.g., 64G, 128G, 256G)")
    var diskSize: String = "64G"

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    @Option(name: .long, help: "Memory size (e.g., 4G, 8G, 16G)")
    var memory: String = "4G"

    @Flag(name: .shortAndLong, help: "Start the VM immediately after creation in interactive mode")
    var interactive: Bool = false

    mutating func validate() throws {
        // Validate CPU count
        let maxCPUs = ProcessInfo.processInfo.processorCount
        guard cpus >= 1 && cpus <= maxCPUs else {
            throw ValidationError("CPU count must be between 1 and \(maxCPUs)")
        }

        // Validate disk size
        let diskManager = DiskManager.shared
        let diskBytes = try diskManager.parseSize(diskSize)
        guard diskBytes >= 1024 * 1024 * 1024 else {  // At least 1GB
            throw ValidationError("Disk size must be at least 1GB")
        }

        // Validate memory
        let memoryBytes = try diskManager.parseSize(memory)
        let minMemory: UInt64 = 512 * 1024 * 1024  // 512MB
        let maxMemory = UInt64(ProcessInfo.processInfo.physicalMemory)
        guard memoryBytes >= minMemory && memoryBytes <= maxMemory else {
            throw ValidationError(
                "Memory must be between 512MB and \(diskManager.formatSize(maxMemory))")
        }
    }

    @MainActor
    mutating func run() async throws {
        let vmManager = Manager.shared
        let diskManager = DiskManager.shared

        // Validate VM name
        try vmManager.validateVMName(name)

        // Check if VM already exists
        if vmManager.vmExists(name) {
            throw ManagerError.vmAlreadyExists(name)
        }

        // Parse sizes
        let diskBytes = try diskManager.parseSize(diskSize)
        let memoryBytes = try diskManager.parseSize(memory)

        // Validate ISO path if provided
        var resolvedISOPath: String?
        if let isoPath = iso {
            let isoURL = try diskManager.validateFileExists(at: isoPath)
            resolvedISOPath = isoURL.path
        }

        // Create configuration
        let config = VMConfiguration.create(
            name: name,
            cpuCount: cpus,
            memorySize: memoryBytes,
            diskSize: diskBytes,
            isoPath: resolvedISOPath
        )

        print("Creating VM '\(name)'...")
        print("  CPUs: \(cpus)")
        print("  Memory: \(diskManager.formatSize(memoryBytes))")
        print("  Disk: \(diskManager.formatSize(diskBytes))")
        if let isoPath = resolvedISOPath {
            print("  ISO: \(isoPath)")
        }

        // Create VM directory and save config
        try vmManager.createVM(config)

        // Create disk image
        let diskPath = vmManager.diskPath(for: name)
        try diskManager.createDiskImage(at: diskPath, size: diskBytes)

        // Generate cloud-init ISO for automatic guest agent configuration
        let sshKeys = readLocalSSHKeys()
        let cloudInitPath = vmManager.cloudInitISOPath(for: name)
        let cloudInitConfiguation = try CloudInitConfiguration.withDefaultPackagesAndCommands(
            instanceID: name, hostname: name, username: ProcessInfo.processInfo.userName,
            sshKeys: sshKeys)
        let cloudInitISOGenerator = CloudInitISOGenerator(configuration: cloudInitConfiguation)
        try await cloudInitISOGenerator.generateISO(at: cloudInitPath)

        // Generate SSH config for direct SSH access
        try vmManager.writeSSHConfig(for: name)

        print("✓ VM '\(name)' created successfully")
        print("  Location: \(vmManager.vmDirectory(for: name).path)")

        if interactive {
            if resolvedISOPath != nil {
                print("\nStarting VM with ISO for installation...")
                print("Press Ctrl-] to detach from console\n")
            } else {
                print("\nStarting VM...")
                print("Press Ctrl-] to detach from console\n")
            }

            // Start the VM in interactive mode
            var startCmd = Start()
            startCmd.name = name
            startCmd.interactive = true
            startCmd.iso = iso != nil
            try await startCmd.run()
        } else {
            if resolvedISOPath != nil {
                print("\nTo install from ISO, run:")
                print("  vm start \(name) --interactive --iso")
            } else {
                print("\nTo start the VM, run:")
                print("  vm start \(name)")
            }
        }
    }
}

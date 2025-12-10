import ArgumentParser
import Foundation
import VMCore

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit the configuration of a virtual machine",
        discussion: """
            Modifies the CPU and/or memory settings for an existing VM.
            The VM must be stopped before editing its configuration.

            Examples:
              vm edit ubuntu --cpus 4
              vm edit debian --memory 8G
              vm edit arch --cpus 8 --memory 16G
            """
    )

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int?

    @Option(name: .long, help: "Memory size (e.g., 4G, 8G, 16G)")
    var memory: String?

    mutating func validate() throws {
        // Ensure at least one option is provided
        guard cpus != nil || memory != nil else {
            throw ValidationError("At least one of --cpus or --memory must be specified")
        }

        // Validate CPU count if provided
        if let cpuCount = cpus {
            let maxCPUs = ProcessInfo.processInfo.processorCount
            guard cpuCount >= 1 && cpuCount <= maxCPUs else {
                throw ValidationError("CPU count must be between 1 and \(maxCPUs)")
            }
        }

        // Validate memory if provided
        if let memoryStr = memory {
            let diskManager = DiskManager.shared
            let memoryBytes = try diskManager.parseSize(memoryStr)
            let minMemory: UInt64 = 512 * 1024 * 1024  // 512MB
            let maxMemory = UInt64(ProcessInfo.processInfo.physicalMemory)
            guard memoryBytes >= minMemory && memoryBytes <= maxMemory else {
                throw ValidationError(
                    "Memory must be between 512MB and \(diskManager.formatSize(maxMemory))")
            }
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

        print("Editing VM '\(name)'...")

        var changes: [String] = []

        // Update CPU count if specified
        if let newCpus = cpus {
            let oldCpus = config.cpuCount
            if newCpus != oldCpus {
                config.cpuCount = newCpus
                changes.append("  CPUs: \(oldCpus) → \(newCpus)")
            } else {
                print("  CPUs: already set to \(oldCpus)")
            }
        }

        // Update memory if specified
        if let memoryStr = memory {
            let newMemoryBytes = try diskManager.parseSize(memoryStr)
            let oldMemoryBytes = config.memorySize
            if newMemoryBytes != oldMemoryBytes {
                config.memorySize = newMemoryBytes
                changes.append(
                    "  Memory: \(diskManager.formatSize(oldMemoryBytes)) → \(diskManager.formatSize(newMemoryBytes))"
                )
            } else {
                print("  Memory: already set to \(diskManager.formatSize(oldMemoryBytes))")
            }
        }

        // Save if there were changes
        if !changes.isEmpty {
            try vmManager.saveConfiguration(config)
            for change in changes {
                print(change)
            }
            print("✓ VM '\(name)' updated successfully")
        } else {
            print("No changes needed.")
        }
    }
}

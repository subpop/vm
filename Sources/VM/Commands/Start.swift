import ArgumentParser
import Foundation
import VMCore
import Virtualization

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a virtual machine",
        discussion: """
            Starts a virtual machine and optionally attaches to its console.

            By default, the VM runs in the background. Use --interactive to
            automatically attach to the console after starting.

            In interactive mode, press Ctrl-] to detach from the console.

            Examples:
              vm start ubuntu
              vm start ubuntu --interactive
              vm start ubuntu --iso  # Boot from ISO
            """
    )

    @Argument(help: "Name of the virtual machine to start")
    var name: String

    @Flag(name: .shortAndLong, help: "Attach to VM console interactively")
    var interactive: Bool = false

    @Flag(name: .long, help: "Boot from ISO image (for installation)")
    var iso: Bool = false

    @MainActor
    mutating func run() async throws {
        let vmManager = Manager.shared

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        // Check if already running
        if vmManager.getRunningPID(for: name) != nil {
            throw RunnerError.alreadyRunning
        }

        // Load configuration
        let config = try vmManager.loadConfiguration(for: name)

        // Validate disk exists
        let diskPath = vmManager.diskPath(for: name)
        guard FileManager.default.fileExists(atPath: diskPath.path) else {
            throw DiskError.fileNotFound(diskPath.path)
        }

        // Check ISO if requested
        if iso {
            guard let isoPath = config.isoPath else {
                throw RunnerError.configurationError(
                    "No ISO configured for this VM. Use 'vm create' with --iso to set one.")
            }
            guard FileManager.default.fileExists(atPath: isoPath) else {
                throw DiskError.fileNotFound(isoPath)
            }
        }

        if interactive {
            // Interactive mode - spawn daemon, then attach
            try await spawnDaemonAndAttach(config: config, manager: vmManager, attachISO: iso)
        } else {
            // Background mode - just spawn daemon
            try await spawnDaemon(config: config, manager: vmManager, attachISO: iso)
        }
    }

    /// Spawns the daemon process only
    @MainActor
    private func spawnDaemon(
        config: VMConfiguration,
        manager: Manager,
        attachISO: Bool
    ) async throws {
        print("Starting VM '\(config.name)'...")
        if attachISO, let isoPath = config.isoPath {
            print("Booting from ISO: \(isoPath)")
        }

        // Spawn daemon process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        var args = ["run-daemon", config.name]
        if attachISO {
            args.append("--iso")
        }
        process.arguments = args

        // Redirect stdout/stderr to /dev/null for true daemonization
        process.standardOutput = nil
        process.standardError = nil
        process.standardInput = nil

        try process.run()

        // Wait for VM to actually start (PID file to appear with valid process)
        var attempts = 0
        while attempts < 50 {  // 5 seconds max
            if manager.getRunningPID(for: config.name) != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            attempts += 1
        }

        guard let pid = manager.getRunningPID(for: config.name) else {
            throw RunnerError.bootError("VM failed to start")
        }

        print("✓ VM '\(config.name)' started (PID: \(pid))")
        print("  Console: vm attach \(config.name)")
        print("  SSH: vm ssh \(config.name)")
    }

    /// Spawns daemon and attaches to console
    @MainActor
    private func spawnDaemonAndAttach(
        config: VMConfiguration,
        manager: Manager,
        attachISO: Bool
    ) async throws {
        let terminal = TerminalController.shared

        // Check if we have a terminal
        guard terminal.isTerminal else {
            print("Warning: Not running in a terminal. Starting in background mode instead.")
            try await spawnDaemon(config: config, manager: manager, attachISO: attachISO)
            return
        }

        print("Starting VM '\(config.name)' in interactive mode...")
        if attachISO, let isoPath = config.isoPath {
            print("Booting from ISO: \(isoPath)")
        }

        // Spawn daemon process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        var args = ["run-daemon", config.name]
        if attachISO {
            args.append("--iso")
        }
        process.arguments = args

        // Don't redirect I/O yet - we'll attach
        process.standardOutput = nil
        process.standardError = nil
        process.standardInput = nil

        try process.run()

        // Wait for console socket to appear
        let socketPath = manager.consoleSocketPath(for: config.name)
        var attempts = 0
        while attempts < 100 {  // 10 seconds max
            if FileManager.default.fileExists(atPath: socketPath.path) {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            attempts += 1
        }

        guard FileManager.default.fileExists(atPath: socketPath.path) else {
            throw RunnerError.bootError("Console socket not available")
        }

        print("Press Ctrl-] to detach from console\n")

        // Connect to the console
        let connection = ConsoleConnection(vmName: config.name, socketPath: socketPath)
        try await connection.connect()
        try await connection.run()
    }
}

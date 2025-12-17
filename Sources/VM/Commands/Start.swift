import ArgumentParser
import Foundation
import VMCore
import Virtualization

// MARK: - Daemon Spawning Utility

/// Arguments for spawning a VM daemon process
struct DaemonSpawnArgs {
    let vmName: String
    var attachISO: Bool = false
    var rescueMode: Bool = false
    var targetDisk: URL? = nil

    /// Build the command-line arguments for run-daemon
    var processArguments: [String] {
        var args = ["run-daemon", vmName]
        if attachISO {
            args.append("--iso")
        }
        if rescueMode {
            args.append("--rescue")
        }
        if let targetDisk = targetDisk {
            args.append(contentsOf: ["--target-disk", targetDisk.path])
        }
        return args
    }
}

/// Result of spawning a daemon and waiting for it to be ready
struct SpawnResult {
    let process: Process
    let socketPath: URL
}

/// Utility for spawning VM daemon processes and connecting to their consoles
enum DaemonSpawner {
    /// Spawns a daemon process in the background without attaching
    /// - Parameters:
    ///   - args: Arguments for the daemon
    ///   - manager: VM manager for path resolution
    /// - Returns: The PID of the started VM
    @MainActor
    static func spawnBackground(args: DaemonSpawnArgs, manager: Manager) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = args.processArguments
        process.standardOutput = nil
        process.standardError = nil
        process.standardInput = nil

        try process.run()

        // Wait for VM to actually start (PID file to appear with valid process)
        var attempts = 0
        while attempts < 50 {  // 5 seconds max
            if manager.getRunningPID(for: args.vmName) != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            attempts += 1
        }

        guard let pid = manager.getRunningPID(for: args.vmName) else {
            throw RunnerError.bootError("VM failed to start")
        }

        return pid
    }

    /// Spawns a daemon and waits for its console socket to be ready
    /// - Parameters:
    ///   - args: Arguments for the daemon
    ///   - manager: VM manager for path resolution
    ///   - timeoutSeconds: How long to wait for the socket (default 10)
    ///   - checkCrash: Whether to check if process has crashed during wait
    /// - Returns: SpawnResult containing the process and socket path
    @MainActor
    static func spawnAndWaitForSocket(
        args: DaemonSpawnArgs,
        manager: Manager,
        timeoutSeconds: Int = 10,
        checkCrash: Bool = false
    ) async throws -> SpawnResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = args.processArguments
        process.standardOutput = nil
        process.standardError = nil
        process.standardInput = nil

        try process.run()

        let socketPath = manager.consoleSocketPath(for: args.vmName)
        let maxAttempts = timeoutSeconds * 10  // 100ms per attempt

        var attempts = 0
        while attempts < maxAttempts {
            if FileManager.default.fileExists(atPath: socketPath.path) {
                return SpawnResult(process: process, socketPath: socketPath)
            }

            // Check if daemon process has crashed
            if checkCrash && !process.isRunning {
                let logPath = manager.logPath(for: args.vmName)
                throw RunnerError.bootError(
                    "Daemon exited unexpectedly (exit code: \(process.terminationStatus)). Check \(logPath.path) for details."
                )
            }

            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            attempts += 1
        }

        // Timeout - check final state
        if checkCrash && !process.isRunning {
            let logPath = manager.logPath(for: args.vmName)
            throw RunnerError.bootError(
                "Daemon exited (exit code: \(process.terminationStatus)). Check \(logPath.path) for details."
            )
        }

        throw RunnerError.bootError(
            "Console socket not available after \(timeoutSeconds) seconds")
    }

    /// Attaches to a VM's console
    /// - Parameters:
    ///   - vmName: Name of the VM
    ///   - socketPath: Path to the console socket
    ///   - messageHandler: Optional callback for console status messages
    @MainActor
    static func attachToConsole(
        vmName: String,
        socketPath: URL,
        messageHandler: ((String) -> Void)? = { print($0) }
    ) async throws {
        let connection = ConsoleConnection(vmName: vmName, socketPath: socketPath, messageHandler: messageHandler)
        try await connection.connect()
        try await connection.run()
    }

    /// Gracefully stops a daemon process
    /// - Parameters:
    ///   - process: The process to stop
    ///   - timeoutSeconds: How long to wait before force killing
    @MainActor
    static func stopDaemon(process: Process, timeoutSeconds: Double = 15) async {
        guard process.isRunning else { return }

        let pid = process.processIdentifier
        if kill(pid, SIGTERM) == 0 {
            let startTime = Date()

            while Date().timeIntervalSince(startTime) < timeoutSeconds {
                if !process.isRunning {
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            }

            // Force kill if still running
            if process.isRunning {
                kill(pid, SIGKILL)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

// MARK: - Start Command

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

        let args = DaemonSpawnArgs(vmName: config.name, attachISO: attachISO)
        let pid = try await DaemonSpawner.spawnBackground(args: args, manager: manager)

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

        let args = DaemonSpawnArgs(vmName: config.name, attachISO: attachISO)
        let result = try await DaemonSpawner.spawnAndWaitForSocket(
            args: args,
            manager: manager,
            timeoutSeconds: 10
        )

        print("Press Ctrl-] to detach from console\n")
        try await DaemonSpawner.attachToConsole(vmName: config.name, socketPath: result.socketPath)
    }
}

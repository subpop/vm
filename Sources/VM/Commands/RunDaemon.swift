import ArgumentParser
import Foundation
import Logging
import VMCore
import Virtualization

/// Internal command to run a VM as a daemon process
/// This command is hidden and used internally by 'vm start' and 'vm rescue'
struct RunDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a virtual machine as a daemon (internal use)",
        shouldDisplay: false  // Hidden from help
    )

    @Argument(help: "Name of the virtual machine to run")
    var name: String

    @Flag(name: .long, help: "Boot from ISO image (for installation)")
    var iso: Bool = false

    @Flag(name: .long, help: "Run in rescue mode (name must be _rescue)")
    var rescue: Bool = false

    @Option(name: .long, help: "Path to target disk to attach in rescue mode")
    var targetDisk: String?

    @MainActor
    mutating func run() async throws {
        let vmManager = Manager.shared

        // Determine VM start options and target disk URL for rescue mode
        var startOptions: VMStartOptions = .normal
        var targetDiskURL: URL?

        if rescue {
            // Validate this is the rescue VM
            guard name == Manager.rescueVMName else {
                throw RunnerError.configurationError(
                    "Rescue mode can only be used with the '\(Manager.rescueVMName)' VM")
            }

            // Validate target disk is provided
            guard let targetDiskPath = targetDisk else {
                throw RunnerError.configurationError("--target-disk is required for rescue mode")
            }

            targetDiskURL = URL(fileURLWithPath: targetDiskPath)
            guard FileManager.default.fileExists(atPath: targetDiskURL!.path) else {
                throw DiskError.fileNotFound(targetDiskPath)
            }

            startOptions = .rescue(targetDisk: targetDiskURL!)
        } else if iso {
            startOptions = VMStartOptions(attachISO: true)
        }

        // Create logger that writes to VM's log file
        let logLabel = rescue ? "rescue-daemon" : "run-daemon"
        let logger = VMLogger.makeLogger(label: logLabel, vmName: name, manager: vmManager)

        if rescue {
            logger.info(
                "Rescue daemon starting",
                metadata: ["target_disk": "\(targetDiskURL?.path ?? "")", "pid": "\(getpid())"]
            )
        } else {
            logger.info("Daemon starting", metadata: ["vm": "\(name)", "pid": "\(getpid())"])
        }

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            logger.error("VM not found", metadata: ["vm": "\(name)"])
            throw ManagerError.vmNotFound(name)
        }

        // Check if VM is already running (only for rescue mode, normal mode checked by caller)
        if rescue && vmManager.getRunningPID(for: name) != nil {
            logger.error("VM is already running")
            throw RunnerError.alreadyRunning
        }

        // Load configuration
        let config = try vmManager.loadConfiguration(for: name)
        logger.info(
            "Configuration loaded",
            metadata: [
                "cpus": "\(config.cpuCount)",
                "memory_gb": "\(config.memorySize / 1024 / 1024 / 1024)",
            ]
        )

        // Validate disk exists
        let diskPath = vmManager.diskPath(for: name)
        guard FileManager.default.fileExists(atPath: diskPath.path) else {
            logger.error("Disk not found", metadata: ["path": "\(diskPath.path)"])
            throw DiskError.fileNotFound(diskPath.path)
        }

        // Check ISO if requested (non-rescue mode only)
        if iso && !rescue {
            guard let isoPath = config.isoPath else {
                logger.error("No ISO configured for VM")
                throw RunnerError.configurationError(
                    "No ISO configured for this VM. Use 'vm create' with --iso to set one.")
            }
            guard FileManager.default.fileExists(atPath: isoPath) else {
                logger.error("ISO not found", metadata: ["path": "\(isoPath)"])
                throw DiskError.fileNotFound(isoPath)
            }
            logger.info("Booting from ISO", metadata: ["path": "\(isoPath)"])
        }

        // Create pipes for serial I/O
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        logger.debug("Serial I/O pipes created")

        // Create the VM runner
        let runner = Runner(config: config, manager: vmManager, logger: logger)
        logger.debug("VM runner created")

        // Save PID
        let runtimeInfo = VMRuntimeInfo(pid: getpid(), startedAt: Date())
        try vmManager.saveRuntimeInfo(runtimeInfo, for: name)
        logger.debug("Runtime info saved")

        defer {
            logger.debug("Cleaning up runtime info")
            try? vmManager.clearRuntimeInfo(for: name)
            if rescue {
                try? vmManager.clearRescueTarget()
            } else {
                try? vmManager.clearNetworkInfo(for: name)
            }
        }

        // Start the VM
        logger.info("Starting VM...")
        do {
            try await runner.start(
                options: startOptions,
                serialInput: inputPipe.fileHandleForReading,
                serialOutput: outputPipe.fileHandleForWriting
            )
        } catch {
            logger.error("Failed to start VM", metadata: ["error": "\(error)"])
            throw error
        }
        logger.info("VM started successfully")

        // Create and start console listener
        let socketPath = vmManager.consoleSocketPath(for: name)
        let listener = ConsoleListener(
            socketPath: socketPath,
            vmInput: inputPipe.fileHandleForWriting,
            vmOutput: outputPipe.fileHandleForReading
        )

        logger.debug("Starting console listener", metadata: ["socket": "\(socketPath.path)"])
        try await listener.start()
        logger.debug("Console listener started")

        defer {
            logger.debug("Stopping console listener")
            Task { @MainActor in
                await listener.stop()
            }
        }

        // Set up exit flag (needed by tasks below)
        let exitFlag = ExitFlag()

        // Create vsock guest agent if socket device is available (normal mode only)
        if !rescue, let socketDevice = runner.guestAgentSocketDevice {
            logger.debug("Creating vsock guest agent", metadata: ["port": "9001"])
            let guestAgent = VsockGuestAgent(socketDevice: socketDevice)

            // Query guest network information in background and save it
            Task {
                logger.debug("Starting guest network query task")
                await queryGuestNetworkInfo(
                    runner: runner, agent: guestAgent, vmName: config.name, saveToFile: true,
                    logger: logger)
                logger.debug("Initial network query complete, starting periodic queries")
                // Start periodic querying
                await periodicGuestNetworkQuery(
                    runner: runner, agent: guestAgent, vmName: config.name, exitFlag: exitFlag,
                    logger: logger)
            }
        } else if !rescue {
            logger.debug("Skipping guest network queries (no guest agent available)")
        }

        // Set up signal handling
        logger.debug("Setting up signal handlers")
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        sigintSource.setEventHandler {
            logger.info("Received SIGINT")
            exitFlag.shouldExit = true
        }
        sigtermSource.setEventHandler {
            logger.info("Received SIGTERM")
            exitFlag.shouldExit = true
        }

        sigintSource.resume()
        sigtermSource.resume()
        logger.debug("Signal handlers active")

        defer {
            logger.debug("Cleaning up signal handlers")
            sigintSource.cancel()
            sigtermSource.cancel()
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }

        logger.debug("Entering main monitoring loop")
        // Wait for VM to stop or signal received
        while !exitFlag.shouldExit {
            if runner.virtualMachine?.state == .stopped || runner.virtualMachine?.state == .error {
                let state = runner.virtualMachine?.state == .stopped ? "stopped" : "error"
                logger.info("VM state changed", metadata: ["state": "\(state)"])
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        }

        if exitFlag.shouldExit && runner.isRunning {
            logger.info("Stopping VM due to exit signal")
            try await runner.stop()
            logger.info("VM stopped")
        } else {
            logger.info("VM stopped naturally")
        }

        logger.info("Daemon exiting")
    }
}

/// Attempts to query network information from the guest agent
/// Returns the interfaces if successful, nil otherwise
@MainActor
private func tryQueryGuestNetwork(
    runner: Runner, agent: VsockGuestAgent, logger: Logger
) async -> [GuestNetworkInterface]? {
    // Check if VM is still running
    guard runner.virtualMachine?.state == .running else {
        logger.debug("VM not running, skipping network query")
        return nil
    }

    // Try to connect to the guest agent (it listens via vsock-listen)
    do {
        try await agent.connect()
        logger.debug("Connected to guest agent")
    } catch {
        logger.debug("Failed to connect to guest agent", metadata: ["error": "\(error)"])
        return nil
    }

    // Try to ping the agent and get network interfaces
    do {
        if try await agent.ping(timeout: 2.0) {
            logger.debug("Guest agent responded to ping")
            if let interfaces = try? await agent.getNetworkInterfaces(timeout: 3.0) {
                logger.debug(
                    "Retrieved network interfaces from guest",
                    metadata: ["count": "\(interfaces.count)"]
                )
                return interfaces
            } else {
                logger.debug("Failed to get network interfaces from guest")
            }
        } else {
            logger.debug("Guest agent ping failed")
        }
    } catch {
        logger.debug("Guest agent query error", metadata: ["error": "\(error)"])
        return nil
    }

    return nil
}

/// Saves guest network information to file
@MainActor
private func saveGuestNetworkInfo(
    _ interfaces: [GuestNetworkInterface], vmName: String, logger: Logger
) {
    let networkInterfaces = interfaces.map { iface in
        VMNetworkInfo.NetworkInterface(
            name: iface.name,
            hwaddr: iface.hwaddr,
            ipAddresses: iface.ipAddresses?.map { ip in
                VMNetworkInfo.NetworkInterface.IPAddress(
                    ipAddressType: ip.ipAddressType,
                    ipAddress: ip.ipAddress,
                    prefix: ip.prefix
                )
            }
        )
    }
    let networkInfo = VMNetworkInfo(interfaces: networkInterfaces, queriedAt: Date())
    try? Manager.shared.saveNetworkInfo(networkInfo, for: vmName)
    logger.debug("Saved network info", metadata: ["vm": "\(vmName)"])
}

/// Queries the guest for network information via QEMU Guest Agent
/// With retries for initial boot detection
@MainActor
private func queryGuestNetworkInfo(
    runner: Runner, agent: VsockGuestAgent, vmName: String? = nil, saveToFile: Bool = false,
    logger: Logger
) async {
    logger.debug("Starting initial network query with retries")

    // Wait a bit for the guest to boot and start the agent
    // Try multiple times with increasing delays
    let retryDelays: [UInt64] = [
        5_000_000_000,  // 5 seconds
        10_000_000_000,  // 10 seconds
        15_000_000_000,  // 15 seconds
        20_000_000_000,  // 20 seconds
    ]

    for (index, delay) in retryDelays.enumerated() {
        logger.debug(
            "Network query attempt",
            metadata: [
                "attempt": "\(index + 1)/\(retryDelays.count)",
                "delay_seconds": "\(delay / 1_000_000_000)",
            ]
        )
        try? await Task.sleep(nanoseconds: delay)

        if let interfaces = await tryQueryGuestNetwork(
            runner: runner, agent: agent, logger: logger)
        {
            logger.debug("Network query succeeded", metadata: ["attempt": "\(index + 1)"])
            // Save to file if requested
            if saveToFile, let vmName = vmName {
                saveGuestNetworkInfo(interfaces, vmName: vmName, logger: logger)
            }
            return
        }
    }

    logger.warning("Network query exhausted all retries without success")
}

/// Periodically queries guest network information and saves it
@MainActor
private func periodicGuestNetworkQuery(
    runner: Runner, agent: VsockGuestAgent, vmName: String, exitFlag: ExitFlag, logger: Logger
) async {
    logger.debug("Starting periodic network query loop", metadata: ["interval_seconds": "60"])

    // Wait for initial query to complete (handled elsewhere)
    try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60 seconds

    var iteration = 0
    while !exitFlag.shouldExit {
        iteration += 1
        logger.debug("Periodic network query", metadata: ["iteration": "\(iteration)"])

        // Try to query network info (single attempt, no retries)
        if let interfaces = await tryQueryGuestNetwork(
            runner: runner, agent: agent, logger: logger)
        {
            saveGuestNetworkInfo(interfaces, vmName: vmName, logger: logger)
        }

        // Wait 60 seconds before next query
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }

    logger.debug("Periodic network query loop exited")
}

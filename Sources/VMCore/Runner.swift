import Foundation
import Logging
import Virtualization

/// Errors that can occur during VM execution
public enum RunnerError: LocalizedError, Sendable {
    case configurationError(String)
    case bootError(String)
    case runtimeError(String)
    case efiNotSupported
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .configurationError(let message):
            return "VM configuration error: \(message)"
        case .bootError(let message):
            return "Boot error: \(message)"
        case .runtimeError(let message):
            return "Runtime error: \(message)"
        case .efiNotSupported:
            return "EFI boot is not supported on this system"
        case .alreadyRunning:
            return "VM is already running"
        }
    }
}

/// Delegate for handling VM state changes
@MainActor
public protocol RunnerDelegate: AnyObject {
    func vmDidStop(error: Error?)
    func vmDidStart()
}

/// Options for starting a VM
public struct VMStartOptions: Sendable {
    /// Whether to attach the configured ISO for installation
    public var attachISO: Bool
    /// Optional secondary disk to attach (e.g., for rescue mode)
    public var secondaryDisk: URL?
    /// Whether to enable the vsock guest agent
    public var enableGuestAgent: Bool
    /// Whether to enable virtiofs directory sharing
    public var enableDirectorySharing: Bool

    public init(
        attachISO: Bool = false,
        secondaryDisk: URL? = nil,
        enableGuestAgent: Bool = true,
        enableDirectorySharing: Bool = true
    ) {
        self.attachISO = attachISO
        self.secondaryDisk = secondaryDisk
        self.enableGuestAgent = enableGuestAgent
        self.enableDirectorySharing = enableDirectorySharing
    }

    /// Default options for normal VM startup
    public static var normal: VMStartOptions {
        VMStartOptions()
    }

    /// Options for rescue mode with a target disk
    public static func rescue(targetDisk: URL) -> VMStartOptions {
        VMStartOptions(
            attachISO: false,
            secondaryDisk: targetDisk,
            enableGuestAgent: false,
            enableDirectorySharing: false
        )
    }
}

/// Runs a Linux VM using Apple Virtualization.framework
@MainActor
public final class Runner: NSObject {
    /// The virtual machine instance
    public private(set) var virtualMachine: VZVirtualMachine?

    /// VM configuration
    public let vmConfig: VMConfiguration

    /// VM manager for paths
    public let vmManager: Manager

    /// Delegate for state changes
    public weak var delegate: RunnerDelegate?

    /// Guest agent vsock device (if enabled)
    public private(set) var guestAgentSocketDevice: VZVirtioSocketDevice?

    /// Logger for this runner
    private let logger: Logger

    /// Whether the VM is running
    public var isRunning: Bool {
        virtualMachine?.state == .running
    }

    public init(config: VMConfiguration, manager: Manager = .shared) {
        self.vmConfig = config
        self.vmManager = manager
        self.logger = VMLogger.logger(for: "runner")
        super.init()
    }

    /// Creates the VZ configuration for the VM with the given options
    /// - Parameters:
    ///   - options: Configuration options for the VM startup
    ///   - serialInput: File handle for serial input
    ///   - serialOutput: File handle for serial output
    /// - Returns: A configured VZVirtualMachineConfiguration
    nonisolated public func createVZConfiguration(
        options: VMStartOptions = .normal,
        serialInput: FileHandle,
        serialOutput: FileHandle
    ) throws -> VZVirtualMachineConfiguration {
        logger.debug(
            "Creating VZ configuration",
            metadata: [
                "vm": "\(vmConfig.name)",
                "guest_agent": "\(options.enableGuestAgent)",
                "directory_sharing": "\(options.enableDirectorySharing)",
            ]
        )

        let config = VZVirtualMachineConfiguration()

        // CPU and memory
        config.cpuCount = vmConfig.cpuCount
        config.memorySize = vmConfig.memorySize
        logger.debug(
            "CPU and memory configured",
            metadata: [
                "cpus": "\(vmConfig.cpuCount)",
                "memory_bytes": "\(vmConfig.memorySize)",
            ]
        )

        // Boot loader - EFI for standard Linux boot
        let efiBootLoader = VZEFIBootLoader()
        let nvramPath = vmManager.nvramPath(for: vmConfig.name)

        if FileManager.default.fileExists(atPath: nvramPath.path) {
            logger.debug("Using existing NVRAM", metadata: ["path": "\(nvramPath.path)"])
            efiBootLoader.variableStore = VZEFIVariableStore(url: nvramPath)
        } else {
            logger.debug("Creating new NVRAM", metadata: ["path": "\(nvramPath.path)"])
            efiBootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramPath)
        }
        config.bootLoader = efiBootLoader

        // Platform configuration
        let platform = VZGenericPlatformConfiguration()
        config.platform = platform

        // Storage devices
        var storageDevices: [VZStorageDeviceConfiguration] = []

        // Main disk
        let diskPath = vmManager.diskPath(for: vmConfig.name)
        if FileManager.default.fileExists(atPath: diskPath.path) {
            logger.debug("Attaching main disk", metadata: ["path": "\(diskPath.path)"])
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: diskPath,
                readOnly: false,
                cachingMode: .cached,
                synchronizationMode: .full
            )
            let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            storageDevices.append(disk)
        }

        // Secondary disk (e.g., target disk in rescue mode)
        if let secondaryDisk = options.secondaryDisk {
            logger.debug(
                "Attaching secondary disk", metadata: ["path": "\(secondaryDisk.path)"])
            let secondaryAttachment = try VZDiskImageStorageDeviceAttachment(
                url: secondaryDisk,
                readOnly: false,
                cachingMode: .cached,
                synchronizationMode: .full
            )
            let secondaryDevice = VZVirtioBlockDeviceConfiguration(attachment: secondaryAttachment)
            storageDevices.append(secondaryDevice)
        }

        // ISO attachment (for installation)
        if options.attachISO, let isoPathString = vmConfig.isoPath {
            let isoURL = URL(fileURLWithPath: (isoPathString as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: isoURL.path) {
                logger.debug("Attaching ISO", metadata: ["path": "\(isoURL.path)"])
                let isoAttachment = try VZDiskImageStorageDeviceAttachment(
                    url: isoURL,
                    readOnly: true
                )
                let iso = VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
                storageDevices.append(iso)
            }
        }

        // Cloud-init ISO (always attached for automatic guest agent configuration)
        let cloudInitPath = vmManager.cloudInitISOPath(for: vmConfig.name)
        if FileManager.default.fileExists(atPath: cloudInitPath.path) {
            logger.debug("Attaching cloud-init ISO", metadata: ["path": "\(cloudInitPath.path)"])
            let cloudInitAttachment = try VZDiskImageStorageDeviceAttachment(
                url: cloudInitPath,
                readOnly: true
            )
            let cloudInitISO = VZUSBMassStorageDeviceConfiguration(attachment: cloudInitAttachment)
            storageDevices.append(cloudInitISO)
        }

        config.storageDevices = storageDevices
        logger.debug(
            "Storage devices configured", metadata: ["count": "\(storageDevices.count)"])

        // Network - NAT
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        // Set MAC address
        if let macAddress = VZMACAddress(string: vmConfig.macAddress) {
            networkDevice.macAddress = macAddress
            logger.debug(
                "Using configured MAC address", metadata: ["mac": "\(vmConfig.macAddress)"])
        } else {
            networkDevice.macAddress = VZMACAddress.randomLocallyAdministered()
            logger.debug(
                "Using random MAC address",
                metadata: ["mac": "\(networkDevice.macAddress.string)"]
            )
        }
        config.networkDevices = [networkDevice]

        // Serial console using virtio console device
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        let serialAttachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: serialInput,
            fileHandleForWriting: serialOutput
        )
        serialConfig.attachment = serialAttachment
        config.serialPorts = [serialConfig]
        logger.debug("Serial console configured")

        // Virtio socket for guest agent communication (if enabled)
        if options.enableGuestAgent {
            let socketDevice = VZVirtioSocketDeviceConfiguration()
            config.socketDevices = [socketDevice]
            logger.debug("Virtio socket configured for guest agent")
        }

        // Entropy device (required for Linux)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon for dynamic memory
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Keyboard and pointer for potential future use
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Share host home directory with guest via virtiofs (if enabled)
        if options.enableDirectorySharing {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            let shareConfig = VZVirtioFileSystemDeviceConfiguration(tag: "hostHome")
            shareConfig.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: homeDirectory, readOnly: false)
            )
            config.directorySharingDevices = [shareConfig]
            logger.debug(
                "Host home directory sharing configured",
                metadata: ["path": "\(homeDirectory.path)"]
            )
        }

        // Validate
        try config.validate()
        logger.debug("VZ configuration validated successfully")

        return config
    }

    /// Starts the VM with the given options
    /// - Parameters:
    ///   - options: Configuration options for the VM startup
    ///   - serialInput: File handle for serial input
    ///   - serialOutput: File handle for serial output
    public func start(
        options: VMStartOptions = .normal,
        serialInput: FileHandle,
        serialOutput: FileHandle
    ) async throws {
        logger.info(
            "Starting VM",
            metadata: [
                "vm": "\(vmConfig.name)",
                "guest_agent": "\(options.enableGuestAgent)",
                "secondary_disk": "\(options.secondaryDisk?.path ?? "none")",
            ]
        )

        guard virtualMachine == nil || virtualMachine?.state == .stopped else {
            logger.error("VM is already running")
            throw RunnerError.alreadyRunning
        }

        let config = try createVZConfiguration(
            options: options,
            serialInput: serialInput,
            serialOutput: serialOutput
        )

        logger.debug("Creating virtual machine instance")
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.virtualMachine = vm

        logger.debug("Calling VZVirtualMachine.start()")
        try await vm.start()
        logger.info("VM started successfully")

        // Capture the socket device for guest agent communication after VM starts
        if options.enableGuestAgent && !vm.socketDevices.isEmpty {
            self.guestAgentSocketDevice = vm.socketDevices[0] as? VZVirtioSocketDevice
            logger.debug("Guest agent socket device captured")
        }

        delegate?.vmDidStart()
    }

    /// Stops the VM gracefully
    public func stop() async throws {
        logger.info("Stopping VM gracefully")

        guard let vm = virtualMachine, vm.state == .running else {
            logger.debug("VM not running, nothing to stop")
            return
        }

        if vm.canRequestStop {
            logger.debug("Requesting graceful stop")
            try vm.requestStop()

            // Wait for the VM to stop gracefully. Linux systems typically need 30-90 seconds
            // to properly shut down services, sync filesystems (especially BTRFS which needs
            // to commit pending transactions), and unmount cleanly.
            let shutdownTimeoutSeconds = 60
            let checkIntervalNs: UInt64 = 500_000_000  // 500ms
            let maxChecks = shutdownTimeoutSeconds * 2

            for _ in 0..<maxChecks {
                try await Task.sleep(nanoseconds: checkIntervalNs)
                if vm.state != .running {
                    logger.debug("VM stopped gracefully")
                    return
                }
            }

            // If still running after timeout, force stop
            if vm.state == .running {
                logger.warning(
                    "VM did not stop gracefully after \(shutdownTimeoutSeconds)s, forcing stop")
                try await forceStop()
            }
        } else {
            logger.debug("Graceful stop not available, forcing stop")
            try await forceStop()
        }
    }

    /// Force stops the VM
    public func forceStop() async throws {
        logger.info("Force stopping VM")
        guard let vm = virtualMachine else {
            logger.debug("No VM instance to stop")
            return
        }

        try await vm.stop()
        logger.info("VM force stopped")
    }

    /// Pauses the VM
    public func pause() async throws {
        logger.info("Pausing VM")
        guard let vm = virtualMachine, vm.state == .running else {
            logger.debug("VM not running, cannot pause")
            return
        }

        try await vm.pause()
        logger.info("VM paused")
    }

    /// Resumes a paused VM
    public func resume() async throws {
        logger.info("Resuming VM")
        guard let vm = virtualMachine, vm.state == .paused else {
            logger.debug("VM not paused, cannot resume")
            return
        }

        try await vm.resume()
        logger.info("VM resumed")
    }

    /// Waits for the VM to stop
    public func waitUntilStopped() async {
        logger.debug("Waiting for VM to stop")
        while virtualMachine?.state == .running || virtualMachine?.state == .starting {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
        logger.debug("VM has stopped")
    }
}

// MARK: - VZVirtualMachineDelegate

extension Runner: VZVirtualMachineDelegate {
    nonisolated public func virtualMachine(
        _ virtualMachine: VZVirtualMachine, didStopWithError error: any Error
    ) {
        logger.error("VM stopped with error", metadata: ["error": "\(error)"])
        Task { @MainActor in
            delegate?.vmDidStop(error: error)
        }
    }

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Guest initiated shutdown")
        Task { @MainActor in
            delegate?.vmDidStop(error: nil)
        }
    }
}

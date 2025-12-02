import ArgumentParser
import Foundation
import VMCore

// MARK: - JSON Output Structures for Info

private struct VMInfoOutput: Codable {
    let name: String
    let status: StatusInfo
    let network: NetworkInfo?
    let hardware: HardwareInfo
    let storage: StorageInfo
    let paths: PathsInfo
    let timestamps: TimestampsInfo

    struct StatusInfo: Codable {
        let state: String
        let pid: Int32?
        let startedAt: Date?
        let uptimeSeconds: Int?
    }

    struct NetworkInfo: Codable {
        let queriedAt: Date
        let primaryIP: String?
        let interfaces: [InterfaceInfo]

        struct InterfaceInfo: Codable {
            let name: String
            let ipAddress: String
        }
    }

    struct HardwareInfo: Codable {
        let cpus: Int
        let memoryBytes: UInt64
        let macAddress: String
    }

    struct StorageInfo: Codable {
        let diskPath: String
        let diskSizeBytes: UInt64
        let allocatedBytes: UInt64?
        let isoPath: String?
    }

    struct PathsInfo: Codable {
        let directory: String
        let config: String
        let nvram: String
    }

    struct TimestampsInfo: Codable {
        let createdAt: Date
        let modifiedAt: Date
    }
}

// MARK: - Info Command

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show detailed information about a virtual machine",
        discussion: """
            Displays detailed configuration and status information for a VM.

            Examples:
              vm info ubuntu
              vm info ubuntu --format json
            """
    )

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Option(help: "Output format")
    var format: OutputFormat = .text

    mutating func run() async throws {
        let vmManager = Manager.shared
        let diskManager = DiskManager.shared

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        let config = try vmManager.loadConfiguration(for: name)
        let isRunning = vmManager.isVMRunning(name)

        switch format {
        case .text:
            printTextOutput(
                config: config, isRunning: isRunning, vmManager: vmManager, diskManager: diskManager
            )
        case .json:
            try printJSONOutput(
                config: config, isRunning: isRunning, vmManager: vmManager, diskManager: diskManager
            )
        }
    }

    private func printTextOutput(
        config: VMConfiguration, isRunning: Bool, vmManager: Manager, diskManager: DiskManager
    ) {
        var rows: [(String, String)] = []

        // Status section
        rows.append(("Status", ""))
        if isRunning {
            if let info = try? vmManager.loadRuntimeInfo(for: name) {
                rows.append(("  State", "running"))
                rows.append(("  PID", "\(info.pid)"))

                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                rows.append(("  Started", formatter.string(from: info.startedAt)))

                let uptime = Date().timeIntervalSince(info.startedAt)
                rows.append(("  Uptime", formatUptime(uptime)))
            } else {
                rows.append(("  State", "running"))
            }
        } else {
            rows.append(("  State", "stopped"))
        }

        // Network section (if running and available)
        if isRunning, let networkInfo = try? vmManager.loadNetworkInfo(for: name) {
            rows.append(("Network", ""))

            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            rows.append(("  Queried", formatter.string(from: networkInfo.queriedAt)))

            // Find primary IP and display interfaces
            var primaryIP: String?
            var displayedInterfaces: [(String, String)] = []

            for iface in networkInfo.interfaces {
                // Skip loopback
                if iface.name == "lo" { continue }

                if let ipAddresses = iface.ipAddresses {
                    for ip in ipAddresses where ip.ipAddressType == "ipv4" {
                        displayedInterfaces.append((iface.name, ip.ipAddress))
                        if primaryIP == nil {
                            primaryIP = ip.ipAddress
                        }
                    }
                }
            }

            if let primary = primaryIP {
                rows.append(("  IP", primary))

                if displayedInterfaces.count > 1 {
                    for (ifaceName, ip) in displayedInterfaces {
                        rows.append(("    \(ifaceName)", ip))
                    }
                }
            } else {
                rows.append(("  IP", "(no IPv4 address)"))
            }
        }

        // Hardware section
        rows.append(("Hardware", ""))
        rows.append(("  CPUs", "\(config.cpuCount)"))
        rows.append(("  Memory", diskManager.formatSize(config.memorySize)))
        rows.append(("  MAC", config.macAddress))

        // Storage section
        rows.append(("Storage", ""))
        let diskPath = vmManager.diskPath(for: name)
        rows.append(("  Disk", diskPath.path))
        rows.append(("  Size", diskManager.formatSize(config.diskSize)))

        if let actualSize = try? diskManager.getDiskSize(at: diskPath) {
            rows.append(("  Allocated", diskManager.formatSize(actualSize)))
        }

        if let isoPath = config.isoPath {
            rows.append(("  ISO", isoPath))
        }

        // Paths section
        rows.append(("Paths", ""))
        rows.append(("  Directory", vmManager.vmDirectory(for: name).path))
        rows.append(("  Config", vmManager.configPath(for: name).path))
        rows.append(("  NVRAM", vmManager.nvramPath(for: name).path))

        // Timestamps section
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        rows.append(("Timestamps", ""))
        rows.append(("  Created", dateFormatter.string(from: config.createdAt)))
        rows.append(("  Modified", dateFormatter.string(from: config.modifiedAt)))

        // Build and render table
        var tableRows: [[String]] = []

        // Add header row with VM name
        tableRows.append([config.name, ""])

        for (key, value) in rows {
            tableRows.append([key, value])
        }

        let table = TableOutput(rows: tableRows)
        print(table.format())
    }

    private func printJSONOutput(
        config: VMConfiguration, isRunning: Bool, vmManager: Manager, diskManager: DiskManager
    ) throws {
        // Build status info
        var state = "stopped"
        var pid: Int32?
        var startedAt: Date?
        var uptimeSeconds: Int?

        if isRunning {
            state = "running"
            if let info = try? vmManager.loadRuntimeInfo(for: name) {
                pid = info.pid
                startedAt = info.startedAt
                uptimeSeconds = Int(Date().timeIntervalSince(info.startedAt))
            }
        }

        let statusInfo = VMInfoOutput.StatusInfo(
            state: state,
            pid: pid,
            startedAt: startedAt,
            uptimeSeconds: uptimeSeconds
        )

        // Build network info
        var networkInfo: VMInfoOutput.NetworkInfo?
        if isRunning, let vmNetworkInfo = try? vmManager.loadNetworkInfo(for: name) {
            var primaryIP: String?
            var interfaces: [VMInfoOutput.NetworkInfo.InterfaceInfo] = []

            for iface in vmNetworkInfo.interfaces {
                if iface.name == "lo" { continue }

                if let ipAddresses = iface.ipAddresses {
                    for ip in ipAddresses where ip.ipAddressType == "ipv4" {
                        interfaces.append(
                            VMInfoOutput.NetworkInfo.InterfaceInfo(
                                name: iface.name,
                                ipAddress: ip.ipAddress
                            ))
                        if primaryIP == nil {
                            primaryIP = ip.ipAddress
                        }
                    }
                }
            }

            networkInfo = VMInfoOutput.NetworkInfo(
                queriedAt: vmNetworkInfo.queriedAt,
                primaryIP: primaryIP,
                interfaces: interfaces
            )
        }

        // Build hardware info
        let hardwareInfo = VMInfoOutput.HardwareInfo(
            cpus: config.cpuCount,
            memoryBytes: config.memorySize,
            macAddress: config.macAddress
        )

        // Build storage info
        let diskPath = vmManager.diskPath(for: name)
        let allocatedBytes = try? diskManager.getDiskSize(at: diskPath)

        let storageInfo = VMInfoOutput.StorageInfo(
            diskPath: diskPath.path,
            diskSizeBytes: config.diskSize,
            allocatedBytes: allocatedBytes,
            isoPath: config.isoPath
        )

        // Build paths info
        let pathsInfo = VMInfoOutput.PathsInfo(
            directory: vmManager.vmDirectory(for: name).path,
            config: vmManager.configPath(for: name).path,
            nvram: vmManager.nvramPath(for: name).path
        )

        // Build timestamps info
        let timestampsInfo = VMInfoOutput.TimestampsInfo(
            createdAt: config.createdAt,
            modifiedAt: config.modifiedAt
        )

        // Create output
        let output = VMInfoOutput(
            name: config.name,
            status: statusInfo,
            network: networkInfo,
            hardware: hardwareInfo,
            storage: storageInfo,
            paths: pathsInfo,
            timestamps: timestampsInfo
        )

        // Encode and print
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(output)
        if let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}

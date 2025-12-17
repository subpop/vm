import ArgumentParser
import Foundation
import VMCore

// MARK: - JSON Output Structure for List

private struct VMListItem: Codable {
    let name: String
    let status: String
    let cpus: Int
    let memoryBytes: UInt64
    let diskSizeBytes: UInt64
}

// MARK: - List Command

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all virtual machines",
        discussion: """
            Lists all virtual machines and their current status.

            Examples:
              vm list
              vm list --format json
            """
    )

    @Option(help: "Output format")
    var format: OutputFormat = .text

    mutating func run() async throws {
        let vmManager = Manager.shared
        let diskManager = DiskManager.shared

        // Filter out the special rescue VM from the list
        let vms = try vmManager.listVMs().filter { $0 != Manager.rescueVMName }

        switch format {
        case .text:
            printTextOutput(vms: vms, vmManager: vmManager, diskManager: diskManager)
        case .json:
            try printJSONOutput(vms: vms, vmManager: vmManager)
        }
    }

    private func printTextOutput(vms: [String], vmManager: Manager, diskManager: DiskManager) {
        if vms.isEmpty {
            print("No virtual machines found")
            print("Create one with: vm create <name> --iso <path>")
            return
        }

        var rows: [[String]] = []

        // Add header row
        rows.append(["NAME", "STATUS", "CPUS", "MEMORY", "DISK"])

        for vmName in vms {
            do {
                let config = try vmManager.loadConfiguration(for: vmName)
                let isRunning = vmManager.isVMRunning(vmName)
                let status = isRunning ? "running" : "stopped"

                let memoryStr = diskManager.formatSize(config.memorySize)
                let diskStr = diskManager.formatSize(config.diskSize)

                rows.append([
                    config.name,
                    status,
                    String(config.cpuCount),
                    memoryStr,
                    diskStr,
                ])
            } catch {
                print(error)
            }
        }

        let table = TableOutput(rows: rows)
        print(table.format())
    }

    private func printJSONOutput(vms: [String], vmManager: Manager) throws {
        var items: [VMListItem] = []

        for vmName in vms {
            do {
                let config = try vmManager.loadConfiguration(for: vmName)
                let isRunning = vmManager.isVMRunning(vmName)
                let status = isRunning ? "running" : "stopped"

                let item = VMListItem(
                    name: config.name,
                    status: status,
                    cpus: config.cpuCount,
                    memoryBytes: config.memorySize,
                    diskSizeBytes: config.diskSize
                )
                items.append(item)
            } catch {
                // Skip VMs that fail to load in JSON output
                continue
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(items)
        if let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
    }
}

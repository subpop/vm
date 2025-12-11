import ArgumentParser
import Foundation
import VMCore

struct IP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: "Print a VM's IP address",
        discussion: """
            Prints the primary IPv4 address of a running virtual machine.

            This command is useful for scripting and is used by the SSH config
            ProxyCommand to resolve VM addresses dynamically.

            Examples:
              vm ip ubuntu
              ssh user@$(vm ip ubuntu)
            """,
        shouldDisplay: false
    )

    @Argument(help: "Name of the virtual machine")
    var name: String

    mutating func run() async throws {
        let vmManager = Manager.shared

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        // Check if VM is running
        guard vmManager.isVMRunning(name) else {
            throw ValidationError(
                "VM '\(name)' is not running. Start it first with 'vm start \(name)'")
        }

        // Load network info
        guard let networkInfo = try vmManager.loadNetworkInfo(for: name) else {
            throw ValidationError(
                "No network information available for VM '\(name)'. "
                    + "The VM may still be booting. Try again in a few seconds.")
        }

        // Find primary IPv4 address
        var primaryIP: String?
        for iface in networkInfo.interfaces {
            // Skip loopback
            if iface.name == "lo" { continue }

            if let ipAddresses = iface.ipAddresses {
                for ip in ipAddresses where ip.ipAddressType == "ipv4" {
                    primaryIP = ip.ipAddress
                    break
                }
            }
            if primaryIP != nil { break }
        }

        guard let ipAddress = primaryIP else {
            throw ValidationError(
                "No IPv4 address found for VM '\(name)'. "
                    + "The network may not be fully configured yet. Try again in a few seconds.")
        }

        // Print just the IP address (no newline for easier scripting)
        print(ipAddress)
    }
}

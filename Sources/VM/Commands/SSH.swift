import ArgumentParser
import Foundation
import VMCore

struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "SSH into a running virtual machine",
        discussion: """
            Connects to a running VM via SSH using the VM's primary IP address.

            The VM must be running and have network connectivity. If the VM was just
            started, wait a few seconds for the network to initialize.

            Examples:
              vm ssh ubuntu
              vm ssh ubuntu --user root
              vm ssh ubuntu -- -v -L 8080:localhost:80
            """
    )

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Option(name: [.short, .customLong("user"), .customShort("l")], help: "SSH username")
    var user: String?

    @Option(name: .shortAndLong, help: "SSH port")
    var port: Int?

    @Argument(parsing: .captureForPassthrough, help: "Additional arguments to pass to ssh")
    var sshArgs: [String] = []

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

        // Build ssh command arguments
        var args: [String] = ["ssh"]

        if let user = user {
            args.append(contentsOf: ["-l", user])
        }

        if let port = port {
            args.append(contentsOf: ["-p", String(port)])
        }

        args.append(ipAddress)
        args.append(contentsOf: sshArgs)

        // Execute ssh, replacing current process
        let cArgs = args.map { strdup($0) } + [nil]
        Darwin.execvp("ssh", cArgs)

        // If execvp returns, it failed
        throw ValidationError("Failed to execute ssh: \(String(cString: strerror(errno)))")
    }
}

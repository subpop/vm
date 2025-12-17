import ArgumentParser
import Foundation
import VMCore

struct Attach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach to a running VM's console",
        discussion: """
            Attaches to the console of a running virtual machine.

            Press Ctrl-] to detach from the console while leaving the VM running.

            Examples:
              vm attach ubuntu
            """,
        aliases: ["console"]
    )

    @Argument(help: "Name of the virtual machine to attach to")
    var name: String

    @MainActor
    mutating func run() async throws {
        let vmManager = Manager.shared

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        // Check if VM is running
        guard vmManager.isVMRunning(name) else {
            throw RunnerError.configurationError(
                "VM '\(name)' is not running. Start it first with 'vm start \(name)'")
        }

        let socketPath = vmManager.consoleSocketPath(for: name)

        // Check if console socket exists
        guard FileManager.default.fileExists(atPath: socketPath.path) else {
            throw RunnerError.configurationError(
                "Console socket not found. VM may still be starting up.")
        }

        print("Attaching to VM '\(name)'...")
        print("Press Ctrl-] to detach from console\n")

        // Connect to the console
        let connection = ConsoleConnection(vmName: name, socketPath: socketPath) { message in
            print(message)
        }
        try await connection.connect()
        try await connection.run()
    }
}

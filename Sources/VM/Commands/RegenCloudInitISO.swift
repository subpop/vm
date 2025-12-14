import ArgumentParser
import Foundation
import VMCore

struct RegenCloudInitISO: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "regen-cloud-init-iso",
        abstract: "Regenerate the cloud-init ISO for an existing VM",
        discussion: """
            Recreates the cloud-init.iso file for an existing virtual machine.
            This is useful if you need to update SSH keys or other cloud-init configuration.

            Note: Changes will only take effect on the next clean boot where cloud-init runs again.
            You may need to clear cloud-init state inside the guest for changes to apply.

            Examples:
              vm regen-cloud-init-iso ubuntu
            """,
        shouldDisplay: false
    )

    @Argument(help: "Name of the virtual machine")
    var name: String

    @MainActor
    mutating func run() async throws {
        let vmManager = Manager.shared

        // Check if VM exists
        guard vmManager.vmExists(name) else {
            throw ManagerError.vmNotFound(name)
        }

        // Load existing configuration to get the VM name for cloud-init
        let config = try vmManager.loadConfiguration(for: name)

        print("Regenerating cloud-init ISO for '\(name)'...")

        // Generate cloud-init ISO using the same logic as Create
        let sshKeys = readLocalSSHKeys()
        let cloudInitPath = vmManager.cloudInitISOPath(for: name)
        let cloudInitConfiguration = try CloudInitConfiguration.withDefaultPackagesAndCommands(
            instanceID: config.name,
            hostname: config.name,
            username: ProcessInfo.processInfo.userName,
            sshKeys: sshKeys
        )
        let cloudInitISOGenerator = CloudInitISOGenerator(configuration: cloudInitConfiguration)
        try await cloudInitISOGenerator.generateISO(at: cloudInitPath)

        print("✓ Cloud-init ISO regenerated successfully")
        print("  Location: \(cloudInitPath.path)")
        print("")
        print(
            "Note: For changes to take effect, you may need to clear cloud-init state in the guest:"
        )
        print("  sudo cloud-init clean --logs && sudo reboot")
    }
}

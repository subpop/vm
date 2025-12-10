// VM - A command-line virtual machine manager for Linux guests
// Using Apple Virtualization.framework

import ArgumentParser
import Foundation
import VMCore

@main
struct VM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "A virtual machine manager for Linux guests",
        discussion: """
            Manage Linux virtual machines.

            VMs are stored in ~/.vm/ with each VM having its own directory
            containing configuration, disk images, and runtime files.

            Getting Started:
              1. Create a VM:         vm create ubuntu --iso ~/Downloads/ubuntu.iso
              2. Start installation:  vm start ubuntu --interactive --iso
              3. After installation:  vm start ubuntu --interactive
              
            For headless operation, omit --interactive to run in background mode.
            """,
        version: "1.0.0",
        subcommands: [
            Create.self,
            Import.self,
            Start.self,
            Stop.self,
            Attach.self,
            SSH.self,
            RunDaemon.self,
            List.self,
            Info.self,
            Edit.self,
            Resize.self,
            Delete.self,
        ],
        defaultSubcommand: List.self
    )
}

// Generate cloud-init ISO for automatic guest agent configuration
func readLocalSSHKeys() -> [String] {
    let fileManager = FileManager.default
    let homeDir = fileManager.homeDirectoryForCurrentUser
    let keyPaths = [
        homeDir.appendingPathComponent(".ssh/id_rsa.pub"),
        homeDir.appendingPathComponent(".ssh/id_ecdsa.pub"),
        homeDir.appendingPathComponent(".ssh/id_ed25519.pub"),
    ]
    var keys: [String] = []
    for keyPath in keyPaths {
        if fileManager.fileExists(atPath: keyPath.path),
            let key = try? String(contentsOf: keyPath, encoding: .utf8)
        {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                keys.append(trimmed)
            }
        }
    }
    return keys
}

// MARK: - Output Format

enum OutputFormat: String, Codable, ExpressibleByArgument, CaseIterable {
    case text
    case json
}

// SignPlugin.swift
// VM
//
// A command plugin that signs program executable with the virtualization entitlement.

import Foundation
import PackagePlugin

@main
struct SignPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Parse arguments for configuration
        var configuration = "debug"
        var argumentExtractor = ArgumentExtractor(arguments)
        if let configArg = argumentExtractor.extractOption(named: "configuration").first {
            configuration = configArg
        }

        // Locate the entitlements file
        let packageDirectory = context.package.directoryURL
        let entitlementsURL =
            packageDirectory
            .appending(path: "Sources/VM/VM.entitlements")

        // Determine the executable path based on configuration
        let buildDirectory = packageDirectory.appending(path: ".build/\(configuration)")
        let executableURL = buildDirectory.appending(path: "VM")

        // Verify the executable exists
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            Diagnostics.error("VM executable not found at \(executableURL.path)")
            Diagnostics.remark("Make sure to run 'swift build' before signing")
            throw SigningError.executableNotFound
        }

        // Verify the entitlements file exists
        guard FileManager.default.fileExists(atPath: entitlementsURL.path) else {
            Diagnostics.error("Entitlements file not found at \(entitlementsURL.path)")
            throw SigningError.entitlementsNotFound
        }

        print("Signing VM with virtualization entitlement...")
        print("  Executable: \(executableURL.path)")
        print("  Entitlements: \(entitlementsURL.path)")
        print("  Configuration: \(configuration)")

        // Run codesign
        let codesign = try context.tool(named: "codesign")
        let process = Process()
        process.executableURL = codesign.url
        process.arguments = [
            "--force",
            "--sign", "-",
            "--entitlements", entitlementsURL.path,
            executableURL.path,
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            Diagnostics.error("codesign failed with exit code \(process.terminationStatus)")
            if !errorOutput.isEmpty {
                Diagnostics.error(errorOutput)
            }
            throw SigningError.codesignFailed(Int(process.terminationStatus))
        }

        print("Successfully signed VM")
    }
}

enum SigningError: Error, CustomStringConvertible {
    case executableNotFound
    case entitlementsNotFound
    case codesignFailed(Int)

    var description: String {
        switch self {
        case .executableNotFound:
            return "VM executable not found. Run 'swift build' first."
        case .entitlementsNotFound:
            return "Entitlements file not found."
        case .codesignFailed(let code):
            return "codesign failed with exit code \(code)"
        }
    }
}

import ArgumentParser
import Foundation
import VMCore

let cloudInitUserDataFragmentFileName = "cloud-init.user-data.yaml"

func validateCloudInitUserDataSourcePath(_ path: String) throws -> URL {
    let expandedPath = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expandedPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ValidationError("Cloud-init user-data file not found: \(path)")
    }
    return url
}

func copyCloudInitUserDataFragment(from sourceURL: URL, to vmDirectory: URL) throws -> String {
    let destinationURL = vmDirectory.appendingPathComponent(cloudInitUserDataFragmentFileName)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return cloudInitUserDataFragmentFileName
}

func loadCloudInitUserDataFragment(config: VMConfiguration, manager: Manager) throws -> String? {
    guard let storedPath = config.cloudInitUserDataPath else {
        return nil
    }

    let fragmentURL: URL
    if storedPath.hasPrefix("/") {
        fragmentURL = URL(fileURLWithPath: storedPath)
    } else {
        fragmentURL = manager.vmDirectory(for: config.name).appendingPathComponent(storedPath)
    }

    guard FileManager.default.fileExists(atPath: fragmentURL.path) else {
        throw ManagerError.configurationError(
            "Cloud-init user-data file not found: \(fragmentURL.path)"
        )
    }

    return try String(contentsOf: fragmentURL, encoding: .utf8)
}

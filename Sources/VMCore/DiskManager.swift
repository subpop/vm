import Foundation

/// Errors that can occur during disk operations
public enum DiskError: LocalizedError, Sendable {
    case fileNotFound(String)
    case diskAlreadyExists(String)
    case creationFailed(String)
    case invalidSize(String)
    case copyFailed(String)
    case resizeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .diskAlreadyExists(let path):
            return "Disk image already exists: \(path)"
        case .creationFailed(let message):
            return "Failed to create disk: \(message)"
        case .invalidSize(let message):
            return "Invalid disk size: \(message)"
        case .copyFailed(let message):
            return "Failed to copy disk: \(message)"
        case .resizeFailed(let message):
            return "Failed to resize disk: \(message)"
        }
    }
}

/// Manages disk image creation and operations
public final class DiskManager: Sendable {
    private var fileManager: FileManager { FileManager.default }

    /// Shared instance
    public static let shared = DiskManager()

    public init() {}

    /// Parses a human-readable size string (e.g., "64G", "512M") into bytes
    public func parseSize(_ sizeString: String) throws -> UInt64 {
        let trimmed = sizeString.trimmingCharacters(in: .whitespaces).uppercased()

        guard !trimmed.isEmpty else {
            throw DiskError.invalidSize("Empty size string")
        }

        let multipliers: [Character: UInt64] = [
            "K": 1024,
            "M": 1024 * 1024,
            "G": 1024 * 1024 * 1024,
            "T": 1024 * 1024 * 1024 * 1024,
        ]

        var numberPart = trimmed
        var multiplier: UInt64 = 1

        if let lastChar = trimmed.last, multipliers.keys.contains(lastChar) {
            multiplier = multipliers[lastChar]!
            numberPart = String(trimmed.dropLast())

            // Handle "GB", "MB", etc.
            if numberPart.hasSuffix("I") {
                numberPart = String(numberPart.dropLast())
            }
            if numberPart.hasSuffix("B") {
                numberPart = String(numberPart.dropLast())
            }
        } else if trimmed.hasSuffix("B") {
            numberPart = String(trimmed.dropLast())
        }

        guard let number = UInt64(numberPart) else {
            throw DiskError.invalidSize("Cannot parse '\(sizeString)' as a size")
        }

        return number * multiplier
    }

    /// Formats a byte count as a human-readable string
    public func formatSize(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unitIndex = 0

        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }

        if size == floor(size) {
            return String(format: "%.0f %@", size, units[unitIndex])
        } else {
            return String(format: "%.1f %@", size, units[unitIndex])
        }
    }

    /// Creates a sparse disk image at the specified path
    public func createDiskImage(at path: URL, size: UInt64) throws {
        if fileManager.fileExists(atPath: path.path) {
            throw DiskError.diskAlreadyExists(path.path)
        }

        // Create parent directory if needed
        let parentDir = path.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Create a sparse file by seeking to the end and writing nothing
        guard fileManager.createFile(atPath: path.path, contents: nil) else {
            throw DiskError.creationFailed("Could not create file at \(path.path)")
        }

        let fileHandle = try FileHandle(forWritingTo: path)
        defer { try? fileHandle.close() }

        // Truncate to create a sparse file of the desired size
        try fileHandle.truncate(atOffset: size)
    }

    /// Copies a disk image to a new location
    public func copyDiskImage(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw DiskError.fileNotFound(source.path)
        }

        if fileManager.fileExists(atPath: destination.path) {
            throw DiskError.diskAlreadyExists(destination.path)
        }

        // Create parent directory if needed
        let parentDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw DiskError.copyFailed(error.localizedDescription)
        }
    }

    /// Gets the size of a disk image file
    public func getDiskSize(at path: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: path.path) else {
            throw DiskError.fileNotFound(path.path)
        }

        let attributes = try fileManager.attributesOfItem(atPath: path.path)
        guard let size = attributes[.size] as? UInt64 else {
            throw DiskError.creationFailed("Could not determine disk size")
        }

        return size
    }

    /// Resizes an existing disk image to a new size
    /// - Parameters:
    ///   - path: Path to the disk image
    ///   - newSize: New size in bytes (must be >= current size)
    public func resizeDiskImage(at path: URL, to newSize: UInt64) throws {
        guard fileManager.fileExists(atPath: path.path) else {
            throw DiskError.fileNotFound(path.path)
        }

        // Get current size
        let currentSize = try getDiskSize(at: path)

        // Validate new size is not smaller (we don't support shrinking)
        guard newSize >= currentSize else {
            throw DiskError.resizeFailed("New size (\(formatSize(newSize))) must be >= current size (\(formatSize(currentSize)))")
        }

        // If sizes are the same, nothing to do
        if newSize == currentSize {
            return
        }

        do {
            let fileHandle = try FileHandle(forWritingTo: path)
            defer { try? fileHandle.close() }

            // Truncate to expand the file
            try fileHandle.truncate(atOffset: newSize)
        } catch {
            throw DiskError.resizeFailed(error.localizedDescription)
        }
    }

    /// Validates that a file exists and is readable
    public func validateFileExists(at path: String) throws -> URL {
        let url: URL
        if path.hasPrefix("/") || path.hasPrefix("~") {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            url = URL(
                fileURLWithPath: path,
                relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath))
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw DiskError.fileNotFound(path)
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw DiskError.fileNotFound("File not readable: \(path)")
        }

        return url
    }
}

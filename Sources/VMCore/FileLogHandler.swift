import Foundation
import Logging
import Synchronization

/// A LogHandler that writes log messages to a file
public struct FileLogHandler: LogHandler, @unchecked Sendable {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .debug

    private let label: String
    private let fileHandle: FileHandle
    private let dateFormatter: ISO8601DateFormatter  // Thread-safe for read-only use after init

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// Creates a FileLogHandler that writes to the specified file URL
    /// - Parameters:
    ///   - label: The logger label
    ///   - fileURL: The URL to write logs to
    /// - Throws: If the file cannot be created or opened
    public init(label: String, fileURL: URL) throws {
        self.label = label
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Create file if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        // Open for appending
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        try self.fileHandle.seekToEnd()
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = dateFormatter.string(from: Date())
        let levelString = level.rawValue.uppercased().padding(
            toLength: 7, withPad: " ", startingAt: 0)

        // Merge metadata
        var combinedMetadata = self.metadata
        if let metadata = metadata {
            combinedMetadata.merge(metadata) { _, new in new }
        }

        var logMessage = "[\(timestamp)] [\(levelString)] [\(label)] \(message)"

        if !combinedMetadata.isEmpty {
            let metadataString = combinedMetadata.map { "\($0.key)=\($0.value)" }.joined(
                separator: " ")
            logMessage += " [\(metadataString)]"
        }

        logMessage += "\n"

        if let data = logMessage.data(using: .utf8) {
            try? fileHandle.write(contentsOf: data)
            try? fileHandle.synchronize()
        }
    }
}

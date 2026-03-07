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

    /// Creates a FileLogHandler that writes to the specified file URL.
    /// Opens a new FileHandle internally; prefer `init(label:fileHandle:)` when
    /// you need explicit control over the file handle's lifecycle.
    public init(label: String, fileURL: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: fileURL)
        try fh.seekToEnd()
        self.init(label: label, fileHandle: fh)
    }

    /// Creates a FileLogHandler backed by an already-open file handle.
    /// The caller retains ownership and is responsible for eventually closing it.
    public init(label: String, fileHandle: FileHandle) {
        self.label = label
        self.fileHandle = fileHandle
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

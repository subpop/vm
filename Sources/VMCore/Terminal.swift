import Foundation

/// Manages terminal raw mode for interactive VM sessions
@MainActor
public final class TerminalController {
    /// Original terminal settings to restore on exit
    private var originalTermios: termios?

    /// Whether we're currently in raw mode
    private var isRawMode = false

    /// File descriptor for stdin
    private var stdinFD: Int32 { FileHandle.standardInput.fileDescriptor }

    /// Shared instance
    public static let shared = TerminalController()

    /// Checks if stdin is a TTY
    public var isTerminal: Bool {
        isatty(stdinFD) != 0
    }

    /// Enables raw mode on the terminal
    /// This disables line buffering and echo, allowing character-by-character input
    public func enableRawMode() throws {
        guard isTerminal else {
            return  // Not a terminal, nothing to do
        }

        guard !isRawMode else {
            return  // Already in raw mode
        }

        // Save current terminal settings
        var raw = termios()
        guard tcgetattr(stdinFD, &raw) == 0 else {
            throw TerminalError.failedToGetAttributes
        }

        originalTermios = raw

        // Modify for raw mode
        // Disable:
        // - ECHO: Don't echo input characters
        // - ICANON: Disable canonical mode (line buffering)
        // - ISIG: Disable signal generation (Ctrl-C, Ctrl-Z)
        // - IEXTEN: Disable extended input processing
        raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))

        // Disable:
        // - IXON: Disable software flow control (Ctrl-S, Ctrl-Q)
        // - ICRNL: Don't translate CR to NL
        // - BRKINT: Don't send SIGINT on break
        // - INPCK: Disable parity checking
        // - ISTRIP: Don't strip 8th bit
        raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))

        // Disable output processing
        raw.c_oflag &= ~(UInt(OPOST))

        // Set character size to 8 bits
        raw.c_cflag |= UInt(CS8)

        // Set minimum characters for read and timeout
        raw.c_cc.16 = 1  // VMIN - minimum characters to read
        raw.c_cc.17 = 0  // VTIME - timeout in deciseconds

        guard tcsetattr(stdinFD, TCSAFLUSH, &raw) == 0 else {
            throw TerminalError.failedToSetAttributes
        }

        isRawMode = true
    }

    /// Disables raw mode and restores original terminal settings
    public func disableRawMode() {
        guard isRawMode, var original = originalTermios else {
            return
        }

        tcsetattr(stdinFD, TCSAFLUSH, &original)
        isRawMode = false
    }

    /// Runs a block with raw mode enabled, restoring settings afterwards
    public func withRawMode<T>(_ block: () throws -> T) throws -> T {
        try enableRawMode()
        defer { disableRawMode() }
        return try block()
    }

    /// Async version of withRawMode
    public func withRawMode<T>(_ block: () async throws -> T) async throws -> T {
        try enableRawMode()
        defer { disableRawMode() }
        return try await block()
    }
}

/// Errors related to terminal operations
public enum TerminalError: LocalizedError, Sendable {
    case failedToGetAttributes
    case failedToSetAttributes
    case notATerminal

    public var errorDescription: String? {
        switch self {
        case .failedToGetAttributes:
            return "Failed to get terminal attributes"
        case .failedToSetAttributes:
            return "Failed to set terminal attributes"
        case .notATerminal:
            return "Not running in a terminal"
        }
    }
}

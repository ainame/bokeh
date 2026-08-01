import Foundation
import SystemPackage
import FltrCSystem
import Synchronization

/// TUI - A Swift Terminal User Interface library
///
/// `RawTerminal` provides low-level terminal control functionality including:
/// - Raw mode activation/deactivation
/// - Alternate screen buffer management
/// - Cursor control and positioning
/// - Terminal size detection
/// - Non-blocking byte reading
///
/// This actor is designed for safe concurrent access to terminal I/O operations.
public actor RawTerminal: Terminal {
    private var originalTermios: termios?
    private var ttyFd: FileDescriptor?
    private var isRawMode = false
    private var inputDecoder = InputDecoder()
    public private(set) var ttyBroken = false  // set on fatal read error (EIO/EBADF)

    // Cleanup state that needs to be accessed from nonisolated context (protected by Mutex)
    private let cleanupState = Mutex<CleanupState?>(nil)

    private struct CleanupState: Sendable {
        let fd: FileDescriptor
        let termios: termios
    }

    public enum TerminalError: Error {
        case failedToGetAttributes
        case failedToSetAttributes
        case failedToGetSize
        case failedToOpenTTY
        case ioError(Errno)
    }

    public init() {}

    deinit {
        // Safety net: ensure terminal is restored even if exitRawMode() wasn't called
        performCleanup()
    }

    /// Enters raw terminal mode and activates the alternate screen buffer.
    ///
    /// Raw mode disables canonical input processing and echo, allowing character-by-character
    /// input reading. The alternate screen buffer preserves the original terminal content.
    ///
    /// - Throws: `TerminalError.failedToOpenTTY` if /dev/tty cannot be opened
    ///           `TerminalError.failedToGetAttributes` if terminal attributes cannot be read
    ///           `TerminalError.failedToSetAttributes` if raw mode cannot be activated
    ///
    /// - Note: Always call `exitRawMode()` to restore terminal state, preferably in a defer block
    public func enterRawMode() throws {
        guard !isRawMode else { return }

        // Open /dev/tty for keyboard input (works even when stdin is piped)
        let fd: FileDescriptor
        do {
            fd = try FileDescriptor.open("/dev/tty", .readWrite)
        } catch {
            throw TerminalError.failedToOpenTTY
        }
        ttyFd = fd

        var raw = termios()
        guard tcgetattr(fd.rawValue, &raw) == 0 else {
            try? fd.close()
            throw TerminalError.failedToGetAttributes
        }

        originalTermios = raw

        // Disable canonical mode, echo, and signals
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        // Disable input processing
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        // Disable output processing
        raw.c_oflag &= ~tcflag_t(OPOST)
        // Set character size
        raw.c_cflag |= tcflag_t(CS8)

        // Non-blocking read with timeout
        fltr_termios_setVMIN(&raw, 0)   // VMIN = 0
        fltr_termios_setVTIME(&raw, 1)  // VTIME = 1 (100ms)

        guard tcsetattr(fd.rawValue, TCSAFLUSH, &raw) == 0 else {
            try? fd.close()
            throw TerminalError.failedToSetAttributes
        }

        // Save cleanup state for deinit safety net
        cleanupState.withLock { $0 = CleanupState(fd: fd, termios: originalTermios!) }

        // Enter alternate screen buffer
        write("\u{001B}[?1049h")
        // Hide cursor
        write("\u{001B}[?25l")
        // Enable mouse tracking (SGR mode with scroll events)
        write("\u{001B}[?1000h")  // Enable mouse tracking
        write("\u{001B}[?1006h")  // Enable SGR extended mouse mode
        // Clear screen
        write("\u{001B}[2J")
        flush()

        isRawMode = true
    }

    /// Exits raw mode and restores original terminal state.
    ///
    /// Restores the terminal to its original state before entering raw mode,
    /// exits the alternate screen buffer, and shows the cursor.
    public func exitRawMode() {
        guard isRawMode else { return }

        // Disable mouse tracking
        write("\u{001B}[?1006l")  // Disable SGR extended mouse mode
        write("\u{001B}[?1000l")  // Disable mouse tracking
        // Show cursor
        write("\u{001B}[?25h")
        // Exit alternate screen buffer
        write("\u{001B}[?1049l")
        flush()

        if let fd = ttyFd, var original = originalTermios {
            // Use TCSADRAIN instead of TCSAFLUSH to wait for output to complete
            // before changing settings. TCSAFLUSH would discard pending escape sequences.
            tcsetattr(fd.rawValue, TCSADRAIN, &original)
            try? fd.close()
        }

        isRawMode = false
        ttyFd = nil

        // Clear cleanup state since we've cleaned up properly
        cleanupState.withLock { $0 = nil }
    }

    /// Nonisolated cleanup method that can be called from deinit
    /// This is a safety net in case exitRawMode() is never called
    nonisolated private func performCleanup() {
        let state = cleanupState.withLock { state in
            defer { state = nil }
            return state
        }

        guard let state else { return }

        // Write cleanup sequences directly to fd
        let cleanupSequence = "\u{001B}[?1006l\u{001B}[?1000l\u{001B}[?25h\u{001B}[?1049l"
        _ = try? state.fd.writeAll(cleanupSequence.utf8)
        fsync(state.fd.rawValue)

        // Restore terminal attributes
        var termios = state.termios
        tcsetattr(state.fd.rawValue, TCSADRAIN, &termios)
        try? state.fd.close()
    }

    /// Gets the current terminal size.
    ///
    /// - Returns: A tuple containing (rows, cols) of the terminal
    /// - Throws: `TerminalError.failedToGetSize` if size cannot be determined
    public func getSize() throws -> (rows: Int, cols: Int) {
        var w = winsize()
        // Use tty fd if available (works when stdout is piped)
        let fd = ttyFd?.rawValue ?? FileDescriptor.standardOutput.rawValue
        let result = withUnsafeMutablePointer(to: &w) { ptr in
            fltr_ioctl_TIOCGWINSZ(fd, ptr)
        }
        guard result == 0 else {
            throw TerminalError.failedToGetSize
        }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    /// Writes a string to the terminal (tty).
    /// Uses /dev/tty when available to avoid contaminating stdout (important for piping).
    ///
    /// - Parameter string: The string to write
    public func write(_ string: String) {
        if let fd = ttyFd {
            _ = try? fd.writeAll(string.utf8)
        } else {
            _ = try? FileDescriptor.standardOutput.writeAll(string.utf8)
        }
    }

    /// Flushes terminal output buffer.
    public func flush() {
        // Terminal writes are displayed by the terminal emulator without a
        // filesystem flush. Avoid a synchronous fsync per interactive frame:
        // it serialises keyboard reads and can make rapid typing feel laggy.
    }

    /// Reads terminal input and decodes semantic key events.
    ///
    /// Returns nil when no full event is available yet.
    public func readInputEvent() -> Key? {
        if let byte = readRawByte() {
            inputDecoder.feed(byte)
        } else {
            inputDecoder.handleTimeout()
        }
        return inputDecoder.nextEvent()
    }

    /// Reads a single byte from terminal input (non-blocking).
    ///
    /// - Returns: The byte read, or nil if no input is available within the VTIME window.
    ///            Sets `ttyBroken` on fatal errors (EIO, EBADF) so the caller can detect
    ///            a closed/disconnected terminal and exit cleanly.
    private func readRawByte() -> UInt8? {
        guard let fd = ttyFd else { return nil }
        var byte: UInt8 = 0
        do {
            let bytesRead = try withUnsafeMutableBytes(of: &byte) { buffer in
                try fd.read(into: buffer)
            }
            return bytesRead == 1 ? byte : nil
        } catch let error as Errno {
            // EIO / EBADF mean the controlling terminal is gone (e.g. the shell closed).
            // EAGAIN is a normal "no data yet" on a non-blocking fd — not fatal.
            if error != .resourceTemporarilyUnavailable {
                ttyBroken = true
            }
            return nil
        } catch {
            ttyBroken = true
            return nil
        }
    }

    /// Moves cursor to the specified position (1-indexed).
    ///
    /// - Parameters:
    ///   - row: Row number (1-based)
    ///   - col: Column number (1-based)
    public func moveCursor(row: Int, col: Int) {
        write("\u{001B}[\(row);\(col)H")
    }

    /// Clears from cursor to end of screen.
    public func clearToEnd() {
        write("\u{001B}[J")
    }

    /// Clears the current line.
    public func clearLine() {
        write("\u{001B}[2K")
    }
}

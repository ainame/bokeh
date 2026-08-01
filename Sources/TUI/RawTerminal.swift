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
    private var inputFd: FileDescriptor?
    private var outputFd: FileDescriptor?
    private var isRawMode = false
    private var inputPumpTask: Task<Void, Never>?
    private var inputGeneration: UInt = 0
    private let inputChannel = TerminalInputChannel()
    private let outputWriter = TerminalOutputWriter()
    public private(set) var ttyBroken = false  // set on fatal read error (EIO/EBADF)

    // Cleanup state that needs to be accessed from nonisolated context (protected by Mutex)
    private let cleanupState = Mutex<CleanupState?>(nil)

    private struct CleanupState: Sendable {
        let inputFd: FileDescriptor
        let outputFd: FileDescriptor
        let termios: termios
    }

    private enum InputRead: Sendable {
        case byte(UInt8)
        case timeout
        case broken
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
        inputPumpTask?.cancel()
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
    public func enterRawMode() async throws {
        guard !isRawMode else { return }

        // Open /dev/tty for keyboard input (works even when stdin is piped)
        let inputFd: FileDescriptor
        do {
            inputFd = try FileDescriptor.open("/dev/tty", .readOnly)
        } catch {
            throw TerminalError.failedToOpenTTY
        }
        let outputFd: FileDescriptor
        do {
            outputFd = try FileDescriptor.open("/dev/tty", .writeOnly)
        } catch {
            try? inputFd.close()
            throw TerminalError.failedToOpenTTY
        }
        self.inputFd = inputFd
        self.outputFd = outputFd

        var raw = termios()
        guard tcgetattr(inputFd.rawValue, &raw) == 0 else {
            try? inputFd.close()
            try? outputFd.close()
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

        guard tcsetattr(inputFd.rawValue, TCSAFLUSH, &raw) == 0 else {
            try? inputFd.close()
            try? outputFd.close()
            throw TerminalError.failedToSetAttributes
        }

        // Save cleanup state for deinit safety net
        cleanupState.withLock {
            $0 = CleanupState(inputFd: inputFd, outputFd: outputFd, termios: originalTermios!)
        }

        // Setup must complete before frames are accepted. Normal UI output is
        // then owned by the separate writer actor.
        _ = try? outputFd.writeAll("\u{001B}[?1049h\u{001B}[?25l\u{001B}[?1000h\u{001B}[?1006h\u{001B}[2J".utf8)
        await outputWriter.start(fd: outputFd)

        isRawMode = true
        ttyBroken = false
        inputGeneration &+= 1
        startInputPump(fd: inputFd, generation: inputGeneration)
    }

    /// Exits raw mode and restores original terminal state.
    ///
    /// Restores the terminal to its original state before entering raw mode,
    /// exits the alternate screen buffer, and shows the cursor.
    public func exitRawMode() async {
        guard isRawMode else { return }

        inputGeneration &+= 1
        inputPumpTask?.cancel()
        if let inputPumpTask {
            // The reader uses VTIME=1, so cancellation becomes observable
            // within 100 ms. Joining it avoids Darwin blocking `close` while
            // another thread is still inside `read(2)` on this descriptor.
            await inputPumpTask.value
        }
        inputPumpTask = nil

        // Serialise cleanup after all queued frames, so a stale frame cannot
        // be written after leaving the alternate screen.
        await outputWriter.stop(finalSequence: "\u{001B}[?1006l\u{001B}[?1000l\u{001B}[?25h\u{001B}[?1049l")

        if let inputFd, var original = originalTermios {
            // The output writer has already been joined above. Do not use
            // TCSADRAIN here: on a detached or heavily loaded PTY it can wait
            // indefinitely even though no fltr write remains in flight.
            tcsetattr(inputFd.rawValue, TCSANOW, &original)
            // Input has a dedicated descriptor. Closing it wakes the blocking
            // byte reader without waiting for the output writer.
            try? inputFd.close()
        }
        try? outputFd?.close()

        isRawMode = false
        self.inputFd = nil
        self.outputFd = nil

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
        _ = try? state.outputFd.writeAll(cleanupSequence.utf8)
        fsync(state.outputFd.rawValue)

        // Restore terminal attributes
        var termios = state.termios
        tcsetattr(state.inputFd.rawValue, TCSANOW, &termios)
        try? state.inputFd.close()
        try? state.outputFd.close()
    }

    /// Gets the current terminal size.
    ///
    /// - Returns: A tuple containing (rows, cols) of the terminal
    /// - Throws: `TerminalError.failedToGetSize` if size cannot be determined
    public func getSize() throws -> (rows: Int, cols: Int) {
        var w = winsize()
        // Use input tty fd if available (works when stdout is piped)
        let fd = inputFd?.rawValue ?? FileDescriptor.standardOutput.rawValue
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
    public nonisolated func write(_ string: String) {
        let writer = outputWriter
        Task { await writer.write(string) }
    }

    /// Flushes terminal output buffer.
    public nonisolated func flush() {
        // Terminal writes are displayed by the terminal emulator without a
        // filesystem flush. Avoid a synchronous fsync per interactive frame:
        // it serialises keyboard reads and can make rapid typing feel laggy.
    }

    /// A lossless stream of decoded input events. The dedicated byte reader
    /// owns the decoder and publishes directly to this stream.
    public func inputEvents() -> AsyncStream<Key> {
        inputChannel.stream
    }

    /// The POSIX read has a VTIME timeout and can block the executing thread.
    /// Keep it in a dedicated detached task so RawTerminal can still service
    /// output and UIController can consume already-decoded events.
    private func startInputPump(fd: FileDescriptor, generation: UInt) {
        let inputChannel = inputChannel
        inputPumpTask = Task.detached { [weak self, inputChannel] in
            var decoder = InputDecoder()
            while !Task.isCancelled {
                let read = Self.readRawByte(from: fd)
                switch read {
                case .byte(let byte): decoder.feed(byte)
                case .timeout: decoder.handleTimeout()
                case .broken:
                    await self?.markTTYBroken(generation: generation)
                    return
                }
                while let key = decoder.nextEvent() {
                    inputChannel.yield(key)
                }
            }
        }
    }

    private func markTTYBroken(generation: UInt) {
        guard isRawMode, generation == inputGeneration else { return }
        ttyBroken = true
    }

    nonisolated private static func readRawByte(from fd: FileDescriptor) -> InputRead {
        var byte: UInt8 = 0
        do {
            let bytesRead = try withUnsafeMutableBytes(of: &byte) { buffer in
                try fd.read(into: buffer)
            }
            return bytesRead == 1 ? .byte(byte) : .timeout
        } catch let error as Errno {
            // EAGAIN is normal on a non-blocking fd; EIO / EBADF mean the
            // controlling terminal has gone away.
            return error == .resourceTemporarilyUnavailable ? .timeout : .broken
        } catch {
            return .broken
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

/// Thread-safe bridge from detached byte reading to the UI reducer.
private final class TerminalInputChannel: @unchecked Sendable {
    let stream: AsyncStream<Key>
    private let continuation: AsyncStream<Key>.Continuation

    init() {
        var captured: AsyncStream<Key>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func yield(_ key: Key) { continuation.yield(key) }
}

/// Owns blocking interactive writes independently from input and state. The
/// one-slot mailbox makes output latest-wins: when the terminal is slow, a
/// burst of prompt/frame updates cannot become a backlog that is rendered
/// long after the user has moved on.
private actor TerminalOutputWriter {
    private var fd: FileDescriptor?
    private var acceptingFrames = false
    private var continuation: AsyncStream<String>.Continuation?
    private var writerTask: Task<Void, Never>?

    func start(fd: FileDescriptor) {
        self.fd = fd
        acceptingFrames = true
        var captured: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(1)) {
            captured = $0
        }
        continuation = captured
        writerTask = Task.detached {
            for await frame in stream {
                guard !Task.isCancelled else { return }
                _ = try? fd.writeAll(frame.utf8)
            }
        }
    }

    func write(_ string: String) {
        guard acceptingFrames else { return }
        continuation?.yield(string)
    }

    func stop(finalSequence: String) async {
        guard let fd else { return }
        acceptingFrames = false
        writerTask?.cancel()
        continuation?.finish()
        if let writerTask {
            await writerTask.value
        }
        writerTask = nil
        continuation = nil
        _ = try? fd.writeAll(finalSequence.utf8)
        self.fd = nil
    }
}

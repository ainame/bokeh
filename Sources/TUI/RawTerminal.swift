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
    private var inputSession: TerminalInputSession?
    private let outputHub = TerminalOutputHub()
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
        outputHub.abandon()
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
        guard fltr_fd_set_nonblocking(outputFd.rawValue) == 0 else {
            try? inputFd.close()
            try? outputFd.close()
            throw TerminalError.ioError(.invalidArgument)
        }
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

        let readerFd: FileDescriptor
        do {
            readerFd = try FileDescriptor.open("/dev/tty", .readOnly)
        } catch {
            var original = originalTermios!
            tcsetattr(inputFd.rawValue, TCSANOW, &original)
            try? inputFd.close()
            try? outputFd.close()
            cleanupState.withLock { $0 = nil }
            throw TerminalError.failedToOpenTTY
        }
        let writerFd: FileDescriptor
        do {
            writerFd = try FileDescriptor.open("/dev/tty", .writeOnly)
        } catch {
            try? readerFd.close()
            var original = originalTermios!
            tcsetattr(inputFd.rawValue, TCSANOW, &original)
            try? inputFd.close()
            try? outputFd.close()
            cleanupState.withLock { $0 = nil }
            throw TerminalError.failedToOpenTTY
        }
        guard fltr_fd_set_nonblocking(writerFd.rawValue) == 0 else {
            try? writerFd.close()
            try? readerFd.close()
            var original = originalTermios!
            tcsetattr(inputFd.rawValue, TCSANOW, &original)
            try? inputFd.close()
            try? outputFd.close()
            cleanupState.withLock { $0 = nil }
            throw TerminalError.ioError(.invalidArgument)
        }

        // Setup must complete before frames are accepted. Normal UI output is
        // then owned by the non-blocking writer session.
        TerminalOutputSession.write(
            "\u{001B}[?1049h\u{001B}[?25l\u{001B}[?1000h\u{001B}[?1006h\u{001B}[2J",
            to: outputFd,
            maximumStalledPolls: 5
        )
        outputHub.open(fd: writerFd)

        self.inputFd = inputFd
        self.outputFd = outputFd
        isRawMode = true
        ttyBroken = false
        inputGeneration &+= 1
        let inputSession = TerminalInputSession()
        self.inputSession = inputSession
        startInputPump(fd: readerFd, generation: inputGeneration, session: inputSession)
    }

    /// Exits raw mode and restores original terminal state.
    ///
    /// Restores the terminal to its original state before entering raw mode,
    /// exits the alternate screen buffer, and shows the cursor.
    public func exitRawMode() async {
        guard isRawMode else { return }

        inputGeneration &+= 1
        inputPumpTask?.cancel()
        inputSession?.finish()
        if let inputPumpTask {
            // The reader uses VTIME=1, so cancellation becomes observable
            // within 100 ms. Joining it avoids Darwin blocking `close` while
            // another thread is still inside `read(2)` on this descriptor.
            await inputPumpTask.value
        }
        inputPumpTask = nil

        // The writer owns a separate non-blocking fd. Joining it is bounded
        // even when the terminal stops accepting output.
        await outputHub.close()

        // No writer can touch this control descriptor. Cleanup remains ordered
        // after the writer has stopped and cannot race a stale frame.
        if let outputFd {
            TerminalOutputSession.write(
                "\u{001B}[?1006l\u{001B}[?1000l\u{001B}[?25h\u{001B}[?1049l",
                to: outputFd,
                maximumStalledPolls: 5
            )
        }

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
        inputSession = nil

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

        // The writer has its own descriptor and is abandoned above, so it
        // cannot race these control writes. The input worker has its own fd,
        // so these control descriptors are safe to close during deinit.
        let cleanupSequence = "\u{001B}[?1006l\u{001B}[?1000l\u{001B}[?25h\u{001B}[?1049l"
        TerminalOutputSession.write(cleanupSequence, to: state.outputFd, maximumStalledPolls: 5)

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
        outputHub.publish(string)
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
        inputSession?.stream ?? AsyncStream { $0.finish() }
    }

    /// The POSIX read has a VTIME timeout and can block the executing thread.
    /// Keep it in a dedicated detached task so RawTerminal can still service
    /// output and UIController can consume already-decoded events.
    private func startInputPump(fd: FileDescriptor, generation: UInt, session: TerminalInputSession) {
        inputPumpTask = Task.detached(priority: .high) { [weak self, session] in
            defer { try? fd.close() }
            var decoder = InputDecoder()
            while !Task.isCancelled {
                let read = Self.readRawByte(from: fd)
                switch read {
                case .byte(let byte): decoder.feed(byte)
                case .timeout: decoder.handleTimeout()
                case .broken:
                    session.finish()
                    await self?.markTTYBroken(generation: generation)
                    return
                }
                while let key = decoder.nextEvent() {
                    session.yield(key)
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

/// A single raw-mode input session. Its continuation is thread-safe; each
/// session is explicitly finished on terminal exit or reader failure.
private final class TerminalInputSession: @unchecked Sendable {
    let stream: AsyncStream<Key>
    private let continuation: AsyncStream<Key>.Continuation

    init() {
        var captured: AsyncStream<Key>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func yield(_ key: Key) { continuation.yield(key) }
    func finish() { continuation.finish() }
}

/// Nonisolated producer boundary for terminal frames. `publish` replaces the
/// pending frame while holding only a short mutex; it never creates a task.
/// The dedicated session below is the sole owner of the write descriptor.
private final class TerminalOutputHub: @unchecked Sendable {
    private let state = Mutex<TerminalOutputSession?>(nil)

    func open(fd: FileDescriptor) {
        let session = TerminalOutputSession(fd: fd)
        state.withLock { current in
            precondition(current == nil, "terminal output session already active")
            current = session
        }
    }

    func publish(_ frame: String) {
        let session = state.withLock { $0 }
        session?.publish(frame)
    }

    func close() async {
        let session = state.withLock { current -> TerminalOutputSession? in
            defer { current = nil }
            return current
        }
        await session?.close()
    }

    nonisolated func abandon() {
        let session = state.withLock { current -> TerminalOutputSession? in
            defer { current = nil }
            return current
        }
        session?.abandon()
    }
}

/// Latest-wins mailbox plus the one task allowed to write a session's fd.
/// `close` cancels that task; writes use O_NONBLOCK and 20 ms poll slices, so
/// teardown cannot wait indefinitely for a backpressured terminal.
private final class TerminalOutputSession: @unchecked Sendable {
    private struct PendingFrame {
        let generation: UInt
        let buffer: String
    }

    private struct State {
        var accepting = true
        var generation: UInt = 0
        var pending: PendingFrame?
    }

    private final class Mailbox: @unchecked Sendable {
        let state = Mutex(State())
    }

    private let mailbox = Mailbox()
    private let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var writerTask: Task<Void, Never>?
    private let fd: FileDescriptor

    init(fd: FileDescriptor) {
        self.fd = fd
        var captured: AsyncStream<Void>.Continuation!
        signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
        let mailbox = self.mailbox
        let signals = self.signals
        writerTask = Task.detached {
            defer { try? fd.close() }
            for await _ in signals {
                guard !Task.isCancelled else { return }
                guard let frame = mailbox.state.withLock({ state -> PendingFrame? in
                    defer { state.pending = nil }
                    return state.accepting ? state.pending : nil
                }) else { continue }
                Self.write(frame.buffer, to: fd) {
                    mailbox.state.withLock { $0.generation == frame.generation }
                }
            }
        }
    }

    func publish(_ frame: String) {
        let shouldSignal = mailbox.state.withLock { state in
            guard state.accepting else { return false }
            state.generation &+= 1
            state.pending = PendingFrame(generation: state.generation, buffer: frame)
            return true
        }
        if shouldSignal { continuation.yield() }
    }

    func close() async {
        mailbox.state.withLock {
            $0.accepting = false
            $0.pending = nil
        }
        writerTask?.cancel()
        continuation.finish()
        if let writerTask { await writerTask.value }
        writerTask = nil
    }

    func abandon() {
        mailbox.state.withLock {
            $0.accepting = false
            $0.pending = nil
        }
        writerTask?.cancel()
        continuation.finish()
        // The worker owns fd and closes it in its defer once cancellation
        // reaches the next bounded poll slice.
    }

    fileprivate static func write(
        _ frame: String,
        to fd: FileDescriptor,
        maximumStalledPolls: Int? = nil,
        isCurrent: (() -> Bool)? = nil
    ) {
        let bytes = Array(frame.utf8)
        var offset = 0
        var stalledPolls = 0
        while offset < bytes.count, !Task.isCancelled {
            guard isCurrent?() ?? true else { return }
            let written = bytes.withUnsafeBytes { buffer in
                fltr_write_bytes(fd.rawValue, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += Int(written)
                stalledPolls = 0
            } else if written == 0 || fltr_errno_is_would_block() != 0 {
                _ = fltr_wait_writable(fd.rawValue, 20)
                stalledPolls += 1
                // A normal frame must eventually complete rather than leave a
                // partial ANSI redraw. Teardown/setup pass a finite bound.
                if let maximumStalledPolls, stalledPolls == maximumStalledPolls { return }
            } else if fltr_errno_is_interrupted() == 0 {
                return
            }
        }
    }
}

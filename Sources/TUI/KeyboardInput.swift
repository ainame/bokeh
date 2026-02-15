import Foundation

/// Keyboard input parsing for terminal applications.
///
/// Converts raw byte sequences into structured key events, handling:
/// - ASCII characters
/// - Control keys (Ctrl-C, Ctrl-D, etc.)
/// - Arrow keys and escape sequences
/// - Special keys (Tab, Enter, Backspace, etc.)
/// - Mouse events (scroll up/down with position)
public enum Key: Equatable, Sendable {
    case char(Character)
    case backspace
    case delete
    case enter
    case escape
    case tab
    case up
    case down
    case left
    case right
    case ctrlC
    case ctrlD
    case ctrlU
    case ctrlK  // Kill line (delete from cursor to end)
    case ctrlO  // Toggle preview
    case ctrlA  // Move to beginning of line
    case ctrlE  // Move to end of line
    case ctrlF  // Move forward one character
    case ctrlB  // Move backward one character
    case ctrlV  // Page down (Emacs-style)
    case altV   // Page up (Emacs-style)
    case mouseScrollUp(col: Int, row: Int)
    case mouseScrollDown(col: Int, row: Int)
    case unknown
}

public struct KeyboardInput {
    static func parseASCIIOrControl(_ byte: UInt8) -> Key? {
        switch byte {
        case 127, 8: return .backspace
        case 9: return .tab
        case 10, 13: return .enter
        case 1: return .ctrlA
        case 2: return .ctrlB
        case 3: return .ctrlC
        case 4: return .ctrlD
        case 5: return .ctrlE
        case 6: return .ctrlF
        case 11: return .ctrlK
        case 14: return .down  // Ctrl-N
        case 15: return .ctrlO
        case 16: return .up    // Ctrl-P
        case 21: return .ctrlU
        case 22: return .ctrlV
        case 32...126:
            return .char(Character(UnicodeScalar(byte)))
        default:
            if byte < 32 {
                return .unknown
            }
            return nil
        }
    }

    static func parseCSICommand(_ byte: UInt8) -> Key {
        switch byte {
        case 65: return .up      // ESC[A
        case 66: return .down    // ESC[B
        case 67: return .right   // ESC[C
        case 68: return .left    // ESC[D
        default: return .unknown
        }
    }

    static func parseMouse(buffer: [UInt8]) -> Key {
        guard
            let payload = String(bytes: buffer, encoding: .utf8),
            !payload.isEmpty
        else {
            return .unknown
        }

        var raw = payload
        _ = raw.removeLast()  // M/m
        let parts = raw.split(separator: ";").compactMap { Int($0) }
        guard parts.count == 3 else { return .unknown }

        let button = parts[0]
        let col = parts[1]
        let row = parts[2]
        switch button {
        case 64: return .mouseScrollUp(col: col, row: row)
        case 65: return .mouseScrollDown(col: col, row: row)
        default: return .unknown
        }
    }

    static func utf8Length(firstByte: UInt8) -> Int? {
        switch firstByte {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (byte & 0b1100_0000) == 0b1000_0000
    }
}

/// Stateful input decoder that converts raw terminal bytes into semantic key events.
public struct InputDecoder: Sendable {
    private enum State: Sendable {
        case idle
        case utf8Pending(bytes: [UInt8], expected: Int)
        case escPending
        case csiPending
        case mousePending(bytes: [UInt8])  // button;col;row + trailing M/m
    }

    private var state: State = .idle
    private var queuedEvents: [Key] = []

    public init() {}

    /// Feed one byte from terminal input.
    public mutating func feed(_ byte: UInt8) {
        switch state {
        case .idle:
            processIdle(byte)

        case .utf8Pending(var bytes, let expected):
            guard KeyboardInput.isUTF8Continuation(byte) else {
                state = .idle
                queuedEvents.append(.unknown)
                processIdle(byte)
                return
            }

            bytes.append(byte)
            if bytes.count < expected {
                state = .utf8Pending(bytes: bytes, expected: expected)
                return
            }

            state = .idle
            guard let scalar = String(bytes: bytes, encoding: .utf8), scalar.count == 1 else {
                queuedEvents.append(.unknown)
                return
            }
            queuedEvents.append(.char(Character(scalar)))

        case .escPending:
            state = .idle
            if byte == 91 {  // '['
                state = .csiPending
                return
            }
            if byte == 118 {  // Alt-V
                queuedEvents.append(.altV)
                return
            }

            // Standalone escape plus next byte treated as fresh input.
            queuedEvents.append(.escape)
            processIdle(byte)

        case .csiPending:
            state = .idle
            if byte == 60 {  // '<' for SGR mouse
                state = .mousePending(bytes: [])
                return
            }
            queuedEvents.append(KeyboardInput.parseCSICommand(byte))

        case .mousePending(var bytes):
            bytes.append(byte)
            if byte == 77 || byte == 109 {  // 'M' or 'm'
                state = .idle
                queuedEvents.append(KeyboardInput.parseMouse(buffer: bytes))
            } else if bytes.count > 50 {
                state = .idle
                queuedEvents.append(.unknown)
            } else {
                state = .mousePending(bytes: bytes)
            }
        }
    }

    /// Tick when no new byte arrived in the current read window.
    /// Used to resolve standalone ESC and stalled multibyte sequences.
    public mutating func handleTimeout() {
        switch state {
        case .idle:
            return
        case .escPending:
            state = .idle
            queuedEvents.append(.escape)
        default:
            state = .idle
            queuedEvents.append(.unknown)
        }
    }

    /// Returns the next decoded event, if available.
    public mutating func nextEvent() -> Key? {
        guard !queuedEvents.isEmpty else { return nil }
        return queuedEvents.removeFirst()
    }

    private mutating func processIdle(_ byte: UInt8) {
        if byte == 27 {  // ESC
            state = .escPending
            return
        }

        if let control = KeyboardInput.parseASCIIOrControl(byte) {
            queuedEvents.append(control)
            return
        }

        guard let expected = KeyboardInput.utf8Length(firstByte: byte) else {
            queuedEvents.append(.unknown)
            return
        }
        state = .utf8Pending(bytes: [byte], expected: expected)
    }
}

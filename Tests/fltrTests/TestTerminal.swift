import TUI
import Synchronization

actor TestTerminal: Terminal {
    private var decoder = InputDecoder()
    private let outputStorage = Mutex<String>("")
    private(set) var enteredRawMode = false
    private var size: (rows: Int, cols: Int)
    private let stream: AsyncStream<Key>
    private let continuation: AsyncStream<Key>.Continuation

    init(rows: Int = 24, cols: Int = 80) {
        self.size = (rows, cols)
        var captured: AsyncStream<Key>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func enterRawMode() async {
        enteredRawMode = true
    }

    func exitRawMode() async {
        enteredRawMode = false
    }

    func getSize() throws -> (rows: Int, cols: Int) {
        size
    }

    nonisolated func write(_ string: String) {
        outputStorage.withLock { $0 += string }
    }

    nonisolated func flush() {}

    var output: String { outputStorage.withLock { $0 } }

    var ttyBroken: Bool { false }

    func inputEvents() -> AsyncStream<Key> {
        stream
    }

    func enqueue(bytes: [UInt8]) {
        for byte in bytes {
            decoder.feed(byte)
            while let key = decoder.nextEvent() {
                continuation.yield(key)
            }
        }
        decoder.handleTimeout()
        while let key = decoder.nextEvent() {
            continuation.yield(key)
        }
    }

    func setSize(rows: Int, cols: Int) {
        size = (rows, cols)
    }

    func clearOutput() {
        outputStorage.withLock { $0.removeAll(keepingCapacity: true) }
    }
}

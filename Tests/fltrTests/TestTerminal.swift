import TUI

actor TestTerminal: Terminal {
    private var inputQueue: [UInt8] = []
    private var decoder = InputDecoder()
    private(set) var output: String = ""
    private(set) var enteredRawMode = false
    private var size: (rows: Int, cols: Int)

    init(rows: Int = 24, cols: Int = 80) {
        self.size = (rows, cols)
    }

    func enterRawMode() {
        enteredRawMode = true
    }

    func exitRawMode() {
        enteredRawMode = false
    }

    func getSize() throws -> (rows: Int, cols: Int) {
        size
    }

    func write(_ string: String) {
        output += string
    }

    func flush() {}

    var ttyBroken: Bool { false }

    func readInputEvent() -> Key? {
        if !inputQueue.isEmpty {
            decoder.feed(inputQueue.removeFirst())
        } else {
            decoder.handleTimeout()
        }
        return decoder.nextEvent()
    }

    func enqueue(bytes: [UInt8]) {
        inputQueue.append(contentsOf: bytes)
    }

    func setSize(rows: Int, cols: Int) {
        size = (rows, cols)
    }

    func clearOutput() {
        output.removeAll(keepingCapacity: true)
    }
}

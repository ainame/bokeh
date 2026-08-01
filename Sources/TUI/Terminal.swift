public protocol Terminal: Actor {
    func enterRawMode() async throws
    func exitRawMode() async
    func getSize() throws -> (rows: Int, cols: Int)
    nonisolated func write(_ string: String)
    nonisolated func flush()
    func inputEvents() -> AsyncStream<Key>
    var ttyBroken: Bool { get }
}

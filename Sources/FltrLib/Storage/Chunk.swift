import Collections

/// Fixed-size chunk for efficient storage
/// Based on fzf's chunk design (100 items per chunk)
///
/// Uses InlineArray (SE-0483) for zero heap allocation
/// Benefits: No heap allocation, better cache locality, no ARC overhead
struct Chunk: Sendable {
    static let capacity = 100
    private var storage: [100 of Item]
    private(set) var count: Int = 0

    init() {
        // Dummy value; unused slots are never read (only 0..<count is valid).
        let dummy = Item(index: -1, offset: 0, length: 0)
        self.storage = .init(repeating: dummy)
    }

    var isFull: Bool {
        count >= Self.capacity
    }

    /// Direct subscript access without array allocation
    subscript(index: Int) -> Item {
        get {
            precondition(index < count, "Index out of bounds")
            return storage[index]
        }
    }

    mutating func append(_ item: Item) -> Bool {
        guard !isFull else { return false }
        storage[count] = item
        count += 1
        return true
    }
}

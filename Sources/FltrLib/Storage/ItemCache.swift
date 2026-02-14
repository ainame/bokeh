/// Thread-safe storage for all items.
///
/// Owns the single ``TextBuffer`` that backs every ``Item`` and the
/// ``ChunkStore`` that holds the chunks.  Text is appended into the buffer
/// first; only then is the ``Item`` (with its offset window) registered in the
/// store.  This ordering guarantees that any ``Item`` that has escaped the actor
/// already has valid bytes behind it.
package actor ItemCache {
    private let store = ChunkStore()
    nonisolated let buffer = TextBuffer()

    package init() {}

    package func append(_ text: String) {
        let index = Int32(store.totalCount)
        let (offset, length) = buffer.append(text)
        let item = Item(index: index, offset: offset, length: length)
        store.append(item)
    }

    /// Register an already-appended byte range as a new Item.
    /// The caller must have appended the bytes to ``buffer`` *before* this call;
    /// this ordering guarantees any Item that escapes the actor has valid backing bytes.
    func registerItem(offset: UInt32, length: UInt32) {
        let index = Int32(store.totalCount)
        let item = Item(index: index, offset: offset, length: length)
        store.append(item)
    }

    package func count() -> Int {
        store.totalCount
    }

    /// Return an O(1) snapshot of the current items.
    /// The snapshot shares frozen chunks with the live store (zero copy);
    /// only the current tail chunk (~2.4 KB) is copied.
    func snapshotChunkList() -> ChunkList {
        store.snapshot()
    }

    /// Reclaim Array growth headroom in both the TextBuffer and the chunk
    /// store.  Call exactly once after stdin is fully consumed.  The transient
    /// cost is one extra copy of each buffer at exact size; the old over-sized
    /// buffer is freed immediately after.
    package func sealAndShrink() {
        store.shrinkToFit()
        buffer.shrinkToFit()
    }
}

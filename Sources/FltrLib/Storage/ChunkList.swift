import Collections

// MARK: - ChunkStore (live, append-only backing)

/// Append-only backing store owned by ``ItemCache``.
///
/// Items arrive one at a time.  The current chunk (``tail``) is mutated in
/// place until it is full, at which point it is sealed into ``frozen`` and a
/// fresh ``tail`` is started.  ``frozen`` is only ever appended to — elements
/// at indices already present never change.
///
/// Snapshots are taken via ``snapshot()`` under actor isolation.  The snapshot
/// captures ``frozen`` by value (Swift CoW: zero physical copy at snapshot time;
/// a copy is materialised only when the *next* chunk seals and appends to
/// ``frozen`` on the store side).  This means the CoW copy fires at most once
/// per 100 items rather than once per item as with the previous design.
///
/// Single-writer discipline is enforced by the owning ``ItemCache`` actor.
final class ChunkStore {
    /// Sealed chunks.  Append-only; elements are immutable after insertion.
    private(set) var frozen: [Chunk] = []

    /// The chunk currently being filled.
    private(set) var tail: Chunk = Chunk()

    /// Total item count (frozen + tail).
    private(set) var totalCount: Int = 0

    func append(_ item: Item) {
        if tail.isFull {
            frozen.append(tail)
            tail = Chunk()
        }
        _ = tail.append(item)
        totalCount += 1
    }

    /// Snapshot: captures ``frozen`` by value (CoW-shared) and copies ``tail``
    /// (~2.4 KB).  The returned ``ChunkList`` is safe to use concurrently with
    /// further appends to this store.
    func snapshot() -> ChunkList {
        ChunkList(frozen: frozen, tailSnapshot: tail, totalCount: totalCount)
    }

    /// Seal the tail into frozen and reallocate ``frozen`` at exact capacity.
    /// Call once after the last append to reclaim Array growth headroom
    /// (~30 % of the frozen buffer).  No-op if already shrunk.
    func shrinkToFit() {
        if tail.count > 0 {
            frozen.append(tail)
            tail = Chunk()
        }
        guard frozen.capacity > frozen.count else { return }
        // Array(_:) doesn't reliably shrink in Swift — create a fresh array
        // with exact capacity to reclaim the ~30% growth headroom.
        var shrunk: [Chunk] = []
        shrunk.reserveCapacity(frozen.count)
        shrunk.append(contentsOf: frozen)
        frozen = shrunk
    }
}

// MARK: - ChunkList (value-type snapshot)

/// A point-in-time, immutable view of the item set.
///
/// ``frozen`` is a CoW-shared copy of the sealed chunks taken at snapshot time.
/// ``tailSnapshot`` is a value copy of the partially-filled tail chunk (~2.4 KB).
/// Both are owned by this struct and safe to read from any thread.
struct ChunkList: Sendable {
    /// Sealed chunks visible to this snapshot (CoW-shared with the store until
    /// the store seals the next chunk).
    private let frozen: [Chunk]
    /// Tail chunk at the moment this snapshot was taken.
    private let tailSnapshot: Chunk
    /// Cached total item count.
    private let cachedCount: Int

    /// Empty list.
    init() {
        self.frozen = []
        self.tailSnapshot = Chunk()
        self.cachedCount = 0
    }

    /// Internal: created by ``ChunkStore.snapshot()``.
    init(frozen: [Chunk], tailSnapshot: Chunk, totalCount: Int) {
        self.frozen = frozen
        self.tailSnapshot = tailSnapshot
        self.cachedCount = totalCount
    }

    var count: Int { cachedCount }

    func forEach(_ body: (Item) throws -> Void) rethrows {
        for ci in 0..<frozen.count {
            let chunk = frozen[ci]
            for i in 0..<chunk.count {
                try body(chunk[i])
            }
        }
        for i in 0..<tailSnapshot.count {
            try body(tailSnapshot[i])
        }
    }

    subscript(index: Int) -> Item? {
        guard index >= 0 && index < cachedCount else { return nil }
        let chunkIdx = index / Chunk.capacity
        let itemIdx  = index % Chunk.capacity
        if chunkIdx < frozen.count {
            return frozen[chunkIdx][itemIdx]
        }
        guard chunkIdx == frozen.count && itemIdx < tailSnapshot.count else { return nil }
        return tailSnapshot[itemIdx]
    }

    // MARK: - Chunk-level access (for per-chunk caching)

    /// Total number of chunks visible to this snapshot (frozen + tail if non-empty).
    var chunkCount: Int {
        tailSnapshot.count > 0 ? frozen.count + 1 : frozen.count
    }

    /// Direct access to a chunk by its index in this snapshot.
    func chunk(at index: Int) -> Chunk {
        if index < frozen.count { return frozen[index] }
        return tailSnapshot
    }
}

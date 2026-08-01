import Foundation

/// Parallel matching engine using Swift structured concurrency
/// Note: Not an actor - matching is a pure computation that should not block input handling
struct MatchingEngine: Sendable {
    private let matcher: FuzzyMatcher
    private let parallelThreshold: Int  // Minimum items to use parallel matching
    /// Leave one cooperative executor worker available for the input reducer,
    /// terminal compositor, and frame scheduling while a search is active.
    private let searchWorkerCount: Int

    init(matcher: FuzzyMatcher, parallelThreshold: Int = 1000, searchWorkerCount: Int? = nil) {
        self.matcher = matcher
        self.parallelThreshold = parallelThreshold
        self.searchWorkerCount = searchWorkerCount ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    /// Match items in parallel using TaskGroup.
    /// Each partition is sorted locally; the caller merges lazily via ResultMerger.
    ///
    /// *items* is a flat ``[Item]`` — used on the incremental-filter path where the
    /// candidate set was extracted from a previous merger.  *buffer* is the shared
    /// ``TextBuffer``; each task opens it independently via ``withBytes``.
    func matchItemsParallel(pattern: String, items: [Item], buffer: TextBuffer, progress: SearchProgress? = nil) async -> ResultMerger {
        guard !pattern.isEmpty else {
            // Score = 0, positions empty → points are (0, byLength, 0, maxU16).
            // Synthesise without opening the buffer.
            let all = items.map { item in
                MatchedItem(item: item, score: 0, minBegin: 0,
                            points: MatchedItem.packPoints(0, UInt16(clamping: Int(item.length)), 0, UInt16.max))
            }
            return ResultMerger(partitions: [all])
        }

        // Prepare the pattern once for all candidates
        let prepared = matcher.prepare(pattern)

        // Small dataset - use single-threaded with buffer reuse
        if items.count < parallelThreshold {
            let results = buffer.withBytes { allBytes in
                var scoringBuffer = matcher.makeBuffer()
                return matchItemsFromBuffer(prepared: prepared, items: items, allBytes: allBytes, scoringBuffer: &scoringBuffer)
            }
            progress?.advance(by: items.count)
            return ResultMerger(partitions: [results])
        }

        // Parallel matching for large datasets
        let partitionSize = max(100, items.count / searchWorkerCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            var startIdx = 0
            while startIdx < items.count {
                let endIdx = min(startIdx + partitionSize, items.count)
                let partStart = startIdx
                let partEnd   = endIdx

                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    return buffer.withBytes { allBytes in
                        var scoringBuffer = self.matcher.makeBuffer()
                        let matches = self.matchItemsFromBuffer(prepared: prepared, items: Array(items[partStart..<partEnd]), allBytes: allBytes, scoringBuffer: &scoringBuffer)
                        progress?.advance(by: partEnd - partStart)
                        return matches
                    }
                }

                startIdx = endIdx
            }

            var partitions = [[MatchedItem]]()
            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                if !partitionResults.isEmpty {
                    partitions.append(partitionResults)
                }
            }
            return ResultMerger(partitions: partitions)
        }
    }

    // MARK: - Chunk-parallel matching with per-chunk cache

    /// Match items by iterating the ChunkList chunk-by-chunk, consulting the
    /// ChunkCache at each step.  Per-chunk flow:
    ///   1. Exact cache hit  → return cached results (zero matching work).
    ///   2. Search hit       → re-match only the cached subset (narrowed).
    ///   3. Full miss        → match every item in the chunk.
    ///   4. Store result if selectivity gate passes (count ≤ queryCacheMax).
    ///
    /// Parallelisation and cancellation logic mirrors ``matchItemsParallel``.
    func matchChunksParallel(pattern: String, chunkList: ChunkList, cache: ChunkCache, buffer: TextBuffer, progress: SearchProgress? = nil) async -> ResultMerger {
        guard !pattern.isEmpty else {
            // Zero-allocation fast path: ChunkList in insertion order IS rank order.
            return .fromChunkList(chunkList)
        }

        let totalChunks = chunkList.chunkCount
        guard totalChunks > 0 else { return .empty }

        // Prepare the pattern once for all candidates
        let prepared = matcher.prepare(pattern)

        let chunksPerPartition = max(1, totalChunks / searchWorkerCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            var startIdx = 0
            while startIdx < totalChunks {
                let endIdx = min(startIdx + chunksPerPartition, totalChunks)
                let partitionStart = startIdx
                let partitionEnd   = endIdx

                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    return buffer.withBytes { allBytes in
                        var scoringBuffer = self.matcher.makeBuffer()
                        var partitionMatches: [MatchedItem] = []

                        for ci in partitionStart..<partitionEnd {
                            guard !Task.isCancelled else { return [] }

                            let chunk = chunkList.chunk(at: ci)

                            // 1. Exact cache hit — zero matching work
                            if let cached = cache.lookup(chunkIndex: ci, chunkCount: chunk.count, query: pattern) {
                                partitionMatches.append(contentsOf: cached)
                                progress?.advance(by: chunk.count)
                                continue
                            }

                            // 2. Search hit — narrow the candidate set
                            let candidates = cache.search(chunkIndex: ci, chunkCount: chunk.count, query: pattern)

                            var chunkResults: [MatchedItem] = []

                            if let candidates = candidates {
                                for (candidateIndex, candidate) in candidates.enumerated() {
                                    if candidateIndex.isMultiple(of: 64), Task.isCancelled {
                                        return []
                                    }
                                    let item = candidate.item
                                    let slice = UnsafeBufferPointer(
                                        start: allBytes.baseAddress! + Int(item.offset),
                                        count: Int(item.length)
                                    )
                                    if let result = self.matcher.matchForRank(prepared, textBuf: slice, buffer: &scoringBuffer) {
                                        chunkResults.append(MatchedItem(item: item, rankMatch: result, scheme: self.matcher.scheme, allBytes: allBytes))
                                    }
                                }
                            } else {
                                // 3. Full miss — match every item in the chunk
                                for i in 0..<chunk.count {
                                    if i.isMultiple(of: 64), Task.isCancelled {
                                        return []
                                    }
                                    let item = chunk[i]
                                    let slice = UnsafeBufferPointer(
                                        start: allBytes.baseAddress! + Int(item.offset),
                                        count: Int(item.length)
                                    )
                                    if let result = self.matcher.matchForRank(prepared, textBuf: slice, buffer: &scoringBuffer) {
                                        chunkResults.append(MatchedItem(item: item, rankMatch: result, scheme: self.matcher.scheme, allBytes: allBytes))
                                    }
                                }
                            }

                            // 4. Store if selectivity gate passes
                            cache.add(chunkIndex: ci, chunkCount: chunk.count, query: pattern, results: chunkResults)

                            partitionMatches.append(contentsOf: chunkResults)
                            progress?.advance(by: chunk.count)
                        }
                        guard !Task.isCancelled else { return [] }
                        // Sort this partition locally — the Merger does the global interleave
                        partitionMatches.sort(by: rankLessThan)
                        return partitionMatches
                    }
                }

                startIdx = endIdx
            }

            var partitions = [[MatchedItem]]()
            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                if !partitionResults.isEmpty {
                    partitions.append(partitionResults)
                }
            }
            return ResultMerger(partitions: partitions)
        }
    }

    // MARK: - Private helpers

    /// Match a slice of items using a pre-opened buffer pointer.
    /// Caller must hold the buffer pointer alive for the duration.
    private func matchItemsFromBuffer(prepared: PreparedPattern, items: [Item], allBytes: UnsafeBufferPointer<UInt8>, scoringBuffer: inout MatcherScratch) -> [MatchedItem] {
        var matched: [MatchedItem] = []
        for (itemIndex, item) in items.enumerated() {
            if itemIndex.isMultiple(of: 64), Task.isCancelled { return [] }
            let slice = UnsafeBufferPointer(
                start: allBytes.baseAddress! + Int(item.offset),
                count: Int(item.length)
            )
            if let result = matcher.matchForRank(prepared, textBuf: slice, buffer: &scoringBuffer) {
                matched.append(MatchedItem(item: item, rankMatch: result, scheme: matcher.scheme, allBytes: allBytes))
            }
        }
        guard !Task.isCancelled else { return [] }
        matched.sort(by: rankLessThan)
        return matched
    }
}

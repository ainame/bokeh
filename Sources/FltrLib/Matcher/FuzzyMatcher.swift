import Foundation

/// Ranking scheme — mirrors fzf's `--scheme` option.
/// Controls which tiebreakers are active after byScore.
///   default  → [byScore, byLength]
///   path     → [byScore, byPathname, byLength]
///   history  → [byScore]          (no tiebreakers)
public enum SortScheme: Sendable {
    case `default`   // byScore, byLength
    case path        // byScore, byPathname, byLength
    case history     // byScore only

    /// Parse a user-supplied string, case-insensitive.  Returns nil on
    /// unrecognised input so the caller can emit a usage error.
    public static func parse(_ s: String) -> SortScheme? {
        switch s.lowercased() {
        case "default": return .default
        case "path":    return .path
        case "history": return .history
        default:        return nil
        }
    }
}

/// Main fuzzy matching interface
public struct FuzzyMatcher: Sendable {
    let caseSensitive: Bool
    let scheme: SortScheme
    private let backend: FuzzyMatchBackend

    public init(caseSensitive: Bool = false, scheme: SortScheme = .path) {
        self.caseSensitive = caseSensitive
        self.scheme = scheme
        self.backend = FuzzyMatchBackend()
    }

    /// Prepare a pattern for repeated matching. Create once per query, reuse across all candidates.
    /// This is the recommended API for matching against many candidates.
    ///
    /// Example:
    /// ```swift
    /// let prepared = matcher.prepare("foo bar")
    /// var buffer = matcher.makeBuffer()
    /// for item in items {
    ///     let result = matcher.match(prepared, textBuf: item.bytes, buffer: &buffer)
    /// }
    /// ```
    public func prepare(_ pattern: String) -> PreparedPattern {
        backend.prepare(pattern, caseSensitive: caseSensitive)
    }

    /// Create a scoring buffer. Call once per thread/task.
    public func makeBuffer() -> MatcherScratch {
        backend.makeScratch()
    }

    /// High-performance rank-only match using prepared pattern and explicit buffer.
    /// This is the hot path used by the matching engine.
    public func matchForRank(
        _ prepared: PreparedPattern,
        textBuf: UnsafeBufferPointer<UInt8>,
        buffer: inout MatcherScratch
    ) -> RankMatch? {
        guard !prepared.lowercasedBytes.isEmpty else {
            return RankMatch(score: 0, minBegin: 0)
        }
        return backend.matchRank(prepared: prepared, textBuf: textBuf, scratch: buffer)
    }

    /// High-performance highlight match using prepared pattern and explicit buffer.
    /// Computes full character positions and is intended for cold paths only.
    public func matchForHighlight(
        _ prepared: PreparedPattern,
        textBuf: UnsafeBufferPointer<UInt8>,
        buffer: inout MatcherScratch
    ) -> MatchResult? {
        guard !prepared.lowercasedBytes.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }
        return backend.matchHighlight(prepared: prepared, textBuf: textBuf, scratch: buffer)
    }

    /// Backward-compatible alias for highlight matching with prepared patterns.
    public func match(
        _ prepared: PreparedPattern,
        textBuf: UnsafeBufferPointer<UInt8>,
        buffer: inout MatcherScratch
    ) -> MatchResult? {
        matchForHighlight(prepared, textBuf: textBuf, buffer: &buffer)
    }

    /// Match a pattern against text.
    /// Query semantics are delegated to the backend.
    public func match(pattern: String, text: String) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }
        return backend.match(pattern: pattern, text: text, caseSensitive: caseSensitive)
    }

    /// Zero-copy overload: *textBuf* is a pre-sliced ``UnsafeBufferPointer``
    /// into a ``TextBuffer``.  Avoids constructing a ``String`` on the hot path.
    /// Multi-token (space-separated AND) is supported; tokens are extracted as
    /// ``Span<UInt8>`` slices of the pattern's UTF-8 — no ``String`` per token.
    public func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }
        return backend.match(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive)
    }

}

/// Item with match result and precomputed ranking points.
///
/// Points are packed into a single UInt64 (lower-is-better) so that the
/// entire rank key compares with a single ``<``.  Bit layout (MSB → LSB):
///   bits 48…63  byScore      (MaxUInt16 − score)                   always active
///   bits 32…47  byPathname   (segment-local distance)              path scheme only; 0 otherwise
///   bits 16…31  byLength     (UTF-8 byte length)                   default & path; 0 for history
///   bits  0…15  unused (0)
struct MatchedItem: Sendable {
    let item: Item
    let rawScore: Int16
    let minBegin: UInt16
    /// Precomputed rank key.  Compare with `rankLessThan(_:_:)`.
    let points: UInt64

    /// Hot-path init: *allBytes* is the live ``TextBuffer`` pointer (held by the
    /// caller's ``withBytes`` scope).  No ``String`` allocation.
    init(item: Item, rankMatch: RankMatch, scheme: SortScheme = .path, allBytes: UnsafeBufferPointer<UInt8>) {
        self.item = item
        self.rawScore = rankMatch.score
        self.minBegin = rankMatch.minBegin
        self.points = MatchedItem.buildPoints(
            offset: Int(item.offset), length: Int(item.length),
            score: rankMatch.score, minBegin: rankMatch.minBegin, scheme: scheme, allBytes: allBytes)
    }

    /// Fast init with pre-computed points — used by the chunkBacked zero-alloc
    /// path where score is 0, positions are empty, and byPathname is irrelevant.
    init(item: Item, score: Int16, minBegin: UInt16, points: UInt64) {
        self.item = item
        self.rawScore = score
        self.minBegin = minBegin
        self.points = points
    }

    /// Compatibility initializer used by tests/callers that still produce
    /// full highlight results.
    init(item: Item, matchResult: MatchResult, scheme: SortScheme = .path, allBytes: UnsafeBufferPointer<UInt8>) {
        self.init(
            item: item,
            rankMatch: RankMatch(score: matchResult.score, minBegin: matchResult.positions.first ?? 0),
            scheme: scheme,
            allBytes: allBytes
        )
    }

    /// Compatibility initializer with pre-computed points.
    init(item: Item, matchResult: MatchResult, points: UInt64) {
        self.init(item: item, score: matchResult.score, minBegin: matchResult.positions.first ?? 0, points: points)
    }

    /// Pack four UInt16 rank slots into a single UInt64.  Argument order
    /// matches the old tuple layout: (unused, byLength, byPathname, byScore).
    @inlinable
    static func packPoints(_ s0: UInt16, _ s1: UInt16, _ s2: UInt16, _ s3: UInt16) -> UInt64 {
        UInt64(s3) << 48 | UInt64(s2) << 32 | UInt64(s1) << 16 | UInt64(s0)
    }

    var score: Int {
        Int(rawScore)
    }

    // MARK: - Rank-point construction  (mirrors fzf result.go : buildResult)

    /// Zero-copy buildPoints: works directly on the raw byte buffer.
    @inlinable
    static func buildPoints(
        offset: Int, length: Int,
        score: Int16, minBegin: UInt16, scheme: SortScheme,
        allBytes: UnsafeBufferPointer<UInt8>
    ) -> UInt64 {
        let maxU16 = Int(UInt16.max)

        // --- byScore (bits 48…63) ---  higher score → lower value  (always active)
        let byScore = UInt16(clamping: maxU16 - Int(score))

        // --- byPathname (bits 32…47) ---  path scheme only
        // Find the last path separator at or before the match start.
        // a match right after a '/' (distance 1) ranks above one mid-segment.
        let byPathname: UInt16
        if case .path = scheme {
            let begin = Int(minBegin)
            var delimBeforeMatch = -1
            let base = allBytes.baseAddress! + offset
            for idx in 0..<min(begin, length) {
                let ch = base[idx]
                if ch == 0x2F || ch == 0x5C {   // '/' or '\'
                    delimBeforeMatch = idx
                }
            }
            byPathname = UInt16(clamping: begin - delimBeforeMatch)
        } else {
            byPathname = 0
        }

        // --- byLength (bits 16…31) ---  default & path schemes only
        let byLength: UInt16
        if case .history = scheme {
            byLength = 0
        } else {
            byLength = UInt16(clamping: length)
        }

        return packPoints(0, byLength, byPathname, byScore)
    }
}

/// Compare two MatchedItems by their packed rank key.
/// Single UInt64 comparison covers all four priority levels;
/// ties broken by original insertion order (item.index ascending).
func rankLessThan(_ a: MatchedItem, _ b: MatchedItem) -> Bool {
    a.points != b.points ? a.points < b.points : a.item.index < b.item.index
}

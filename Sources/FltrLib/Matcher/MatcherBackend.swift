import Foundation
import FuzzyMatch

/// Per-task scratch storage for matcher backends.
/// Backends may reuse internal buffers through this object.
public final class MatcherScratch: @unchecked Sendable {
    struct QueryKey: Hashable {
        let pattern: String
        let caseSensitive: Bool
    }

    var fuzzyBuffer: FuzzyMatch.ScoringBuffer = FuzzyMatch.ScoringBuffer()
    var queryCache: [QueryKey: FuzzyMatch.FuzzyQuery] = [:]

    public init() {}
}

struct FuzzyMatchBackend: Sendable {
    // We delegate tokenization/AND semantics to Fltr's FuzzyMatcher layer.
    private let matcher = FuzzyMatch.FuzzyMatcher(
        config: FuzzyMatch.MatchConfig(minScore: 0.0, algorithm: .smithWaterman())
    )

    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern {
        PreparedPattern(pattern: pattern, caseSensitive: caseSensitive)
    }

    func makeScratch() -> MatcherScratch {
        MatcherScratch()
    }

    func matchRank(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> RankMatch? {
        let query = preparedQuery(for: prepared, scratch: scratch)
        let text = String(decoding: textBuf, as: UTF8.self)
        guard let scored = matcher.score(text, against: query, buffer: &scratch.fuzzyBuffer) else {
            return nil
        }

        guard let positions = matchPositions(pattern: prepared.lowercasedBytes, textBuf: textBuf, caseSensitive: prepared.caseSensitive) else {
            return nil
        }

        let minBegin = positions.first ?? 0
        return RankMatch(score: normalizeScore(scored.score), minBegin: minBegin)
    }

    func matchHighlight(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult? {
        let query = preparedQuery(for: prepared, scratch: scratch)
        let text = String(decoding: textBuf, as: UTF8.self)
        guard let scored = matcher.score(text, against: query, buffer: &scratch.fuzzyBuffer) else {
            return nil
        }

        guard let positions = matchPositions(pattern: prepared.lowercasedBytes, textBuf: textBuf, caseSensitive: prepared.caseSensitive) else {
            return nil
        }

        return MatchResult(score: normalizeScore(scored.score), positions: positions)
    }

    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult? {
        let prepared = prepare(pattern, caseSensitive: caseSensitive)
        let scratch = makeScratch()
        return text.utf8.withContiguousStorageIfAvailable { ptr in
            let textBuf = UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count)
            return matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
        } ?? {
            let bytes = Array(text.utf8)
            return bytes.withUnsafeBufferPointer { textBuf in
                matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
            }
        }()
    }

    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult? {
        let prepared = prepare(pattern, caseSensitive: caseSensitive)
        let scratch = makeScratch()
        return matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
    }

    private func preparedQuery(for prepared: PreparedPattern, scratch: MatcherScratch) -> FuzzyMatch.FuzzyQuery {
        let key = MatcherScratch.QueryKey(pattern: prepared.original, caseSensitive: prepared.caseSensitive)
        if let cached = scratch.queryCache[key] {
            return cached
        }
        let query = matcher.prepare(prepared.original)
        scratch.queryCache[key] = query
        return query
    }

    @inline(__always)
    private func normalizeScore(_ score: Double) -> Int16 {
        Int16(clamping: Int((score * 10_000).rounded(.toNearestOrAwayFromZero)))
    }

    @inline(__always)
    private func folded(_ b: UInt8, caseSensitive: Bool) -> UInt8 {
        if caseSensitive {
            return b
        }
        return (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
    }

    /// Selects match positions for rank/highlight:
    /// 1) contiguous exact substring when present (prefer word-bounded),
    /// 2) otherwise greedy fuzzy subsequence fallback.
    private func matchPositions(pattern: [UInt8], textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        guard !pattern.isEmpty else { return [] }
        guard pattern.count <= textBuf.count else { return nil }

        // Prefer exact contiguous spans for highlight/minBegin when available.
        // This prevents scattered greedy picks (e.g. letters matched across path segments).
        if let start = findContiguousSubstringStart(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive) {
            return (0..<pattern.count).map { UInt16(clamping: start + $0) }
        }
        // Fall back to classic fuzzy subsequence positions when exact span doesn't exist.
        return greedyMatchPositions(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive)
    }

    private func findContiguousSubstringStart(
        pattern: [UInt8],
        textBuf: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> Int? {
        let pLen = pattern.count
        let tLen = textBuf.count
        guard pLen > 0, pLen <= tLen else { return nil }

        var firstMatch: Int?
        for start in 0...(tLen - pLen) {
            var isMatch = true
            for i in 0..<pLen {
                // Reuse the same ASCII case-folding logic as matching, so rank/highlight
                // position recovery honors case-sensitive vs insensitive mode consistently.
                let tb = folded(textBuf[start + i], caseSensitive: caseSensitive)
                let pb = folded(pattern[i], caseSensitive: caseSensitive)
                if tb != pb {
                    isMatch = false
                    break
                }
            }
            guard isMatch else { continue }

            if firstMatch == nil {
                firstMatch = start
            }
            // Prefer token-like matches (word/path boundaries on both sides),
            // but remember the first contiguous hit as a stable fallback.
            if isWholeWordMatch(start: start, length: pLen, textBuf: textBuf) {
                return start
            }
        }

        return firstMatch
    }

    @inline(__always)
    private func isWholeWordMatch(start: Int, length: Int, textBuf: UnsafeBufferPointer<UInt8>) -> Bool {
        let end = start + length

        // Boundary rule: either edge of string, or adjacent byte is non-alnum.
        // This treats separators such as '/', '_', '-', '.', and spaces as boundaries.
        let startBoundary = start == 0 || !isASCIIAlnum(textBuf[start - 1])
        let endBoundary = end >= textBuf.count || !isASCIIAlnum(textBuf[end])
        return startBoundary && endBoundary
    }

    @inline(__always)
    private func isASCIIAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39)
            || (b >= 0x41 && b <= 0x5A)
            || (b >= 0x61 && b <= 0x7A)
    }

    private func greedyMatchPositions(pattern: [UInt8], textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        guard !pattern.isEmpty else { return [] }
        guard pattern.count <= textBuf.count else { return nil }

        var positions: [UInt16] = []
        positions.reserveCapacity(pattern.count)

        var textIndex = 0
        for pb in pattern {
            let foldedPattern = folded(pb, caseSensitive: caseSensitive)
            var found = false
            while textIndex < textBuf.count {
                let tb = textBuf[textIndex]
                if folded(tb, caseSensitive: caseSensitive) == foldedPattern {
                    positions.append(UInt16(clamping: textIndex))
                    textIndex += 1
                    found = true
                    break
                }
                textIndex += 1
            }
            if !found {
                return nil
            }
        }

        return positions
    }
}

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

        guard let positions = matchPositionsForRank(prepared: prepared, textBuf: textBuf, caseSensitive: prepared.caseSensitive) else {
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

        guard let positions = matchPositionsForHighlight(prepared: prepared, textBuf: textBuf, caseSensitive: prepared.caseSensitive) else {
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

    /// Rank path keeps byte-oriented positions (fast ASCII hot path and stable
    /// rank semantics for byPathname/minBegin).
    private func matchPositionsForRank(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        matchPositionsByte(prepared: prepared, textBuf: textBuf, caseSensitive: caseSensitive)
    }

    /// Highlight path emits character-index positions for non-ASCII candidates
    /// so UI highlighting aligns with grapheme traversal.
    private func matchPositionsForHighlight(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        if isASCII(textBuf), prepared.lowercasedBytes.allSatisfy({ $0 < 0x80 }) {
            return matchPositionsByte(prepared: prepared, textBuf: textBuf, caseSensitive: caseSensitive)
        }
        return matchPositionsUnicode(prepared: prepared, textBuf: textBuf, caseSensitive: caseSensitive)
    }

    /// Recovers byte-index positions by preferring contiguous atom matches, then
    /// greedy fallback. This mirrors legacy behavior and stays on the hot path.
    private func matchPositionsByte(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        let pattern = prepared.lowercasedBytes
        guard !pattern.isEmpty else { return [] }

        // Mirror upstream Smith-Waterman splitSpaces behavior:
        // only when there are 2+ non-empty atoms split by ASCII spaces.
        if prepared.atomRanges.count > 1 {
            return pattern.withUnsafeBufferPointer { patternBuf in
                guard let base = patternBuf.baseAddress else { return nil }

                var merged: [UInt16] = []
                merged.reserveCapacity(pattern.count)

                for atom in prepared.atomRanges {
                    guard atom.length <= textBuf.count else { return nil }
                    let atomBuf = UnsafeBufferPointer(start: base + atom.start, count: atom.length)
                    guard let atomPositions = matchSinglePatternPositions(
                        patternBuf: atomBuf,
                        textBuf: textBuf,
                        caseSensitive: caseSensitive
                    ) else {
                        return nil
                    }
                    merged.append(contentsOf: atomPositions)
                }

                guard !merged.isEmpty else { return nil }
                merged.sort()
                var unique: [UInt16] = []
                unique.reserveCapacity(merged.count)
                var previous: UInt16?
                for p in merged where p != previous {
                    unique.append(p)
                    previous = p
                }
                return unique
            }
        }

        guard pattern.count <= textBuf.count else { return nil }
        return pattern.withUnsafeBufferPointer { patternBuf in
            matchSinglePatternPositions(patternBuf: patternBuf, textBuf: textBuf, caseSensitive: caseSensitive)
        }
    }

    private func matchPositionsUnicode(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        guard !prepared.lowercasedBytes.isEmpty else { return [] }

        let rawText = String(decoding: textBuf, as: UTF8.self)
        let normalizedText = caseSensitive ? rawText : rawText.lowercased()
        let textChars = Array(normalizedText)

        if prepared.atomRanges.count > 1 {
            var merged: [UInt16] = []
            merged.reserveCapacity(prepared.lowercasedBytes.count)

            for atom in prepared.atomRanges {
                let end = atom.start + atom.length
                guard end <= prepared.lowercasedBytes.count else { return nil }
                let atomBytes = prepared.lowercasedBytes[atom.start..<end]
                guard let atomPattern = String(bytes: atomBytes, encoding: .utf8) else { return nil }
                guard let atomPositions = matchSinglePatternPositionsUnicode(pattern: Array(atomPattern), text: textChars) else {
                    return nil
                }
                merged.append(contentsOf: atomPositions)
            }

            guard !merged.isEmpty else { return nil }
            merged.sort()
            var unique: [UInt16] = []
            unique.reserveCapacity(merged.count)
            var previous: UInt16?
            for p in merged where p != previous {
                unique.append(p)
                previous = p
            }
            return unique
        }

        guard let pattern = String(bytes: prepared.lowercasedBytes, encoding: .utf8) else {
            return nil
        }
        return matchSinglePatternPositionsUnicode(pattern: Array(pattern), text: textChars)
    }

    private func matchSinglePatternPositions(
        patternBuf: UnsafeBufferPointer<UInt8>,
        textBuf: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> [UInt16]? {
        guard !patternBuf.isEmpty else { return [] }
        guard patternBuf.count <= textBuf.count else { return nil }

        if let start = findContiguousSubstringStart(patternBuf: patternBuf, textBuf: textBuf, caseSensitive: caseSensitive) {
            return (0..<patternBuf.count).map { UInt16(clamping: start + $0) }
        }
        return greedyMatchPositions(patternBuf: patternBuf, textBuf: textBuf, caseSensitive: caseSensitive)
    }

    private func findContiguousSubstringStart(
        patternBuf: UnsafeBufferPointer<UInt8>,
        textBuf: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> Int? {
        let pLen = patternBuf.count
        let tLen = textBuf.count
        guard pLen > 0, pLen <= tLen else { return nil }

        for start in 0...(tLen - pLen) {
            var isMatch = true
            for i in 0..<pLen {
                let tb = folded(textBuf[start + i], caseSensitive: caseSensitive)
                let pb = folded(patternBuf[i], caseSensitive: caseSensitive)
                if tb != pb {
                    isMatch = false
                    break
                }
            }
            if isMatch { return start }
        }
        return nil
    }

    private func greedyMatchPositions(patternBuf: UnsafeBufferPointer<UInt8>, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        guard !patternBuf.isEmpty else { return [] }
        guard patternBuf.count <= textBuf.count else { return nil }

        var positions: [UInt16] = []
        positions.reserveCapacity(patternBuf.count)

        var textIndex = 0
        for pb in patternBuf {
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

    private func matchSinglePatternPositionsUnicode(pattern: [Character], text: [Character]) -> [UInt16]? {
        guard !pattern.isEmpty else { return [] }
        guard pattern.count <= text.count else { return nil }

        if let start = findContiguousSubstringStartUnicode(pattern: pattern, text: text) {
            return (0..<pattern.count).map { UInt16(clamping: start + $0) }
        }
        return greedyMatchPositionsUnicode(pattern: pattern, text: text)
    }

    private func findContiguousSubstringStartUnicode(pattern: [Character], text: [Character]) -> Int? {
        let pLen = pattern.count
        let tLen = text.count
        guard pLen > 0, pLen <= tLen else { return nil }

        for start in 0...(tLen - pLen) {
            var isMatch = true
            for i in 0..<pLen where text[start + i] != pattern[i] {
                isMatch = false
                break
            }
            if isMatch { return start }
        }
        return nil
    }

    private func greedyMatchPositionsUnicode(pattern: [Character], text: [Character]) -> [UInt16]? {
        guard !pattern.isEmpty else { return [] }
        guard pattern.count <= text.count else { return nil }

        var positions: [UInt16] = []
        positions.reserveCapacity(pattern.count)

        var textIndex = 0
        for p in pattern {
            var found = false
            while textIndex < text.count {
                if text[textIndex] == p {
                    positions.append(UInt16(clamping: textIndex))
                    textIndex += 1
                    found = true
                    break
                }
                textIndex += 1
            }
            if !found { return nil }
        }

        return positions
    }

    @inline(__always)
    private func isASCII(_ textBuf: UnsafeBufferPointer<UInt8>) -> Bool {
        for b in textBuf where b >= 0x80 {
            return false
        }
        return true
    }
}

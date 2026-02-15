/// A pattern pre-processed for repeated matching. Create once per query,
/// reuse across all candidates. Analogous to FuzzyMatch's `FuzzyQuery`.
///
/// This struct eliminates redundant per-candidate work by pre-computing:
/// - Lowercased UTF-8 bytes of the pattern (for case-insensitive matching)
///
/// Example:
/// ```swift
/// let pattern = matcher.prepare("foo")
/// for item in items {
///     var buffer = matcher.makeBuffer()
///     let result = matcher.match(pattern, textBuf: item.bytes, buffer: &buffer)
/// }
/// ```
public struct PreparedPattern: Sendable {
    public struct AtomRange: Sendable {
        public let start: Int
        public let length: Int
    }

    /// Original pattern string (kept for display and debugging)
    public let original: String

    /// Pre-lowercased UTF-8 bytes of the full pattern.
    /// Used for case-insensitive matching to avoid repeated toLower calls.
    public let lowercasedBytes: [UInt8]

    /// Whether case-sensitive matching was requested.
    public let caseSensitive: Bool

    /// Query atoms split on ASCII spaces, matching upstream Smith-Waterman
    /// splitSpaces behavior (drop empty segments between repeated spaces).
    public let atomRanges: [AtomRange]

    /// Create a prepared pattern from a query string.
    ///
    /// - Parameters:
    ///   - pattern: The search pattern.
    ///   - caseSensitive: Whether to perform case-sensitive matching
    public init(pattern: String, caseSensitive: Bool = false) {
        self.original = pattern
        self.caseSensitive = caseSensitive

        // Pre-lowercase the entire pattern for case-insensitive matching
        let lowercased = caseSensitive ? pattern : pattern.lowercased()
        let bytes = Array(lowercased.utf8)
        self.lowercasedBytes = bytes
        self.atomRanges = Self.computeAtomRanges(bytes)
    }

    private static func computeAtomRanges(_ bytes: [UInt8]) -> [AtomRange] {
        guard bytes.contains(0x20) else { return [] }

        var ranges: [AtomRange] = []
        var segStart = 0

        for i in 0..<bytes.count {
            if bytes[i] == 0x20 {
                if i > segStart {
                    ranges.append(AtomRange(start: segStart, length: i - segStart))
                }
                segStart = i + 1
            }
        }

        if bytes.count > segStart {
            ranges.append(AtomRange(start: segStart, length: bytes.count - segStart))
        }
        return ranges
    }
}

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
    /// Original pattern string (kept for display and debugging)
    public let original: String

    /// Pre-lowercased UTF-8 bytes of the full pattern.
    /// Used for case-insensitive matching to avoid repeated toLower calls.
    public let lowercasedBytes: [UInt8]

    /// Whether case-sensitive matching was requested.
    public let caseSensitive: Bool

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
        self.lowercasedBytes = Array(lowercased.utf8)
    }
}

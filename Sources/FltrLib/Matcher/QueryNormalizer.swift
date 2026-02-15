/// Normalizes user queries for matching semantics.
/// Display code should keep the raw query string; matching paths should use this.
enum QueryNormalizer {
    static func normalizeForMatching(_ query: String) -> String {
        let parts = query.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}


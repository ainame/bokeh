import Testing
@testable import FltrLib

// MARK: - Test Helpers

/// A thin wrapper that keeps a ``TextBuffer`` alive alongside the ``Item``
/// instances it backs.  Avoids scattering buffer lifetimes across every test.
private struct ItemSet: Sendable {
    let buffer: TextBuffer
    let items: [Item]

    /// Text of the item at *index* in this set.
    func text(of item: Item) -> String { item.text(in: buffer) }
}

/// Build a single Item + its backing buffer.
private func makeItem(index: Int, text: String) -> ItemSet {
    let buffer = TextBuffer()
    let (offset, length) = buffer.append(text)
    return ItemSet(buffer: buffer, items: [Item(index: Int32(index), offset: offset, length: length)])
}

/// Build an array of Items sharing one TextBuffer (mirrors production layout).
private func makeItems(_ texts: [String]) -> ItemSet {
    let buffer = TextBuffer()
    let items = texts.enumerated().map { (i, text) -> Item in
        let (offset, length) = buffer.append(text)
        return Item(index: Int32(i), offset: offset, length: length)
    }
    return ItemSet(buffer: buffer, items: items)
}

/// Convenience: build an ItemSet from an explicit list of (index, text) pairs
/// so that callers can keep their original per-item index values.
private func makeItems(_ pairs: [(Int, String)]) -> ItemSet {
    let buffer = TextBuffer()
    let items = pairs.map { (i, text) -> Item in
        let (offset, length) = buffer.append(text)
        return Item(index: Int32(i), offset: offset, length: length)
    }
    return ItemSet(buffer: buffer, items: items)
}

/// Run FuzzyMatcher.match over every item, collect hits, sort by rank.
/// Uses the real buildPoints path so that rank ordering in tests matches
/// production behaviour (score + pathname + length).
private func matchItems(matcher: FuzzyMatcher, pattern: String, items: [Item], buffer: TextBuffer) -> [MatchedItem] {
    var results: [MatchedItem] = []
    buffer.withBytes { allBytes in
        for item in items {
            if let result = matcher.match(pattern: pattern, text: item.text(in: buffer)) {
                results.append(MatchedItem(item: item, matchResult: result, allBytes: allBytes))
            }
        }
    }
    results.sort { rankLessThan($0, $1) }
    return results
}

/// Overload that accepts an ItemSet directly.
private func matchItems(matcher: FuzzyMatcher, pattern: String, set: ItemSet) -> [MatchedItem] {
    matchItems(matcher: matcher, pattern: pattern, items: set.items, buffer: set.buffer)
}

/// Run both rank and highlight code paths against one candidate text.
private func matchRankAndHighlight(
    matcher: FuzzyMatcher,
    query: String,
    text: String
) -> (RankMatch?, MatchResult?) {
    let prepared = matcher.prepare(query)
    var scratch = matcher.makeBuffer()
    return text.utf8.withContiguousStorageIfAvailable { ptr in
        let textBuf = UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count)
        let rank = matcher.matchForRank(prepared, textBuf: textBuf, buffer: &scratch)
        let highlight = matcher.matchForHighlight(prepared, textBuf: textBuf, buffer: &scratch)
        return (rank, highlight)
    } ?? {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { textBuf in
            let rank = matcher.matchForRank(prepared, textBuf: textBuf, buffer: &scratch)
            let highlight = matcher.matchForHighlight(prepared, textBuf: textBuf, buffer: &scratch)
            return (rank, highlight)
        }
    }()
}

// MARK: - Basic Matching Tests

@Test("Basic fuzzy matching")
func basicMatching() {
    let matcher = FuzzyMatcher(caseSensitive: false)

    // Should match
    #expect(matcher.match(pattern: "ap", text: "apple") != nil)
    #expect(matcher.match(pattern: "ban", text: "banana") != nil)
    #expect(matcher.match(pattern: "che", text: "cherry") != nil)

    // Should not match
    #expect(matcher.match(pattern: "xyz", text: "apple") == nil)
}

@Test("Case insensitive matching")
func caseInsensitiveMatching() {
    let matcher = FuzzyMatcher(caseSensitive: false)

    #expect(matcher.match(pattern: "APP", text: "apple") != nil)
    #expect(matcher.match(pattern: "app", text: "APPLE") != nil)
}

@Test("Case sensitive matching")
func caseSensitiveMatching() {
    let matcher = FuzzyMatcher(caseSensitive: true)

    // Should match
    #expect(matcher.match(pattern: "app", text: "apple") != nil)

    // Should not match (case mismatch)
    #expect(matcher.match(pattern: "APP", text: "apple") == nil)
}

@Test("Empty pattern matches with zero score")
func emptyPattern() {
    let matcher = FuzzyMatcher()

    let result = matcher.match(pattern: "", text: "apple")
    #expect(result != nil)
    #expect(result?.score == 0)
    #expect(result?.positions == [] as [UInt16])
}

@Test("Match positions tracking")
func matchPositions() {
    let matcher = FuzzyMatcher()

    let result = matcher.match(pattern: "ae", text: "apple")
    #expect(result != nil)
    // Pattern "ae" should match positions 0 (a) and 4 (e)
    #expect(result?.positions.count == 2)
    #expect(result?.positions.contains(0) == true)
}

@Test("Exact contiguous substring is preferred for highlight positions")
func exactContiguousSubstringHighlight() {
    let matcher = FuzzyMatcher(caseSensitive: false)
    let text = "gist.github.com/ainame/career"

    let (_, highlight) = matchRankAndHighlight(matcher: matcher, query: "career", text: text)
    #expect(highlight != nil)
    #expect(highlight?.positions == [23, 24, 25, 26, 27, 28] as [UInt16])
}

@Test("Rank minBegin stays consistent with highlight first position")
func rankMinBeginMatchesHighlightStart() {
    let matcher = FuzzyMatcher(caseSensitive: false)
    let text = "gist.github.com/ainame/career"

    let (rank, highlight) = matchRankAndHighlight(matcher: matcher, query: "career", text: text)
    #expect(rank != nil)
    #expect(highlight != nil)
    #expect(rank?.minBegin == highlight?.positions.first)
}

@Test("Case-insensitive contiguous recovery for exact substring")
func caseInsensitiveContiguousRecovery() {
    let matcher = FuzzyMatcher(caseSensitive: false)
    let text = "gist.github.com/ainame/Career"

    let (_, highlight) = matchRankAndHighlight(matcher: matcher, query: "career", text: text)
    #expect(highlight != nil)
    #expect(highlight?.positions == [23, 24, 25, 26, 27, 28] as [UInt16])
}

@Test("Falls back to fuzzy subsequence when no contiguous substring exists")
func fallbackToGreedySubsequenceWithoutContiguous() {
    let matcher = FuzzyMatcher(caseSensitive: false)
    let text = "gist.github.com/ainame/career"

    let (_, highlight) = matchRankAndHighlight(matcher: matcher, query: "crr", text: text)
    #expect(highlight != nil)
    #expect(highlight?.positions == [12, 25, 28] as [UInt16])
}

@Test("Match scoring validation")
func matchScoring() {
    let matcher = FuzzyMatcher()

    let result1 = matcher.match(pattern: "app", text: "apple")
    let result2 = matcher.match(pattern: "xyz", text: "apple")

    #expect(result1 != nil)
    #expect(result2 == nil)
    #expect(result1!.score > 0)
}

@Test("Word boundary bonus scoring")
func wordBoundaryBonus() {
    let matcher = FuzzyMatcher()

    let result1 = matcher.match(pattern: "fb", text: "foo_bar")
    let result2 = matcher.match(pattern: "fb", text: "foobar")

    #expect(result1 != nil)
    #expect(result2 != nil)

    // "foo_bar" with delimiter should score higher
    #expect(result1!.score > result2!.score)
}

@Test("Match multiple items")
func matchItems() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "apple"),
        (1, "apricot"),
        (2, "banana"),
        (3, "cherry"),
    ])

    let results = matchItems(matcher: matcher, pattern: "ap", set: set)

    // Should match "apple" and "apricot"
    #expect(results.count == 2)
    #expect(results.contains { set.text(of: $0.item) == "apple" })
    #expect(results.contains { set.text(of: $0.item) == "apricot" })

    // Results should be sorted by score (descending)
    if results.count >= 2 {
        #expect(results[0].score >= results[1].score)
    }
}

@Test("Empty pattern matches all items")
func emptyPatternMatchesAll() {
    let matcher = FuzzyMatcher()
    let set = makeItems(["apple", "banana", "cherry"])

    let results = matchItems(matcher: matcher, pattern: "", set: set)
    #expect(results.count == 3)
}

// MARK: - Whitespace Semantics Tests

@Test("Whitespace is handled by backend semantics")
func whitespaceBackendSemantics() {
    let matcher = FuzzyMatcher()

    // Smith-Waterman splitSpaces=true: "swift util" is two atoms with AND semantics.
    #expect(matcher.match(pattern: "swift util", text: "swift-argument-parser/Tools/changelog-authors/Util.swift") != nil)
    #expect(matcher.match(pattern: "swift util", text: "swift util") != nil)
    #expect(matcher.match(pattern: "swift util", text: "swift-only") == nil)
}

@Test("Whitespace query over multiple items follows backend semantics")
func whitespaceBackendOrdering() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "swift-util-tools"),
        (1, "swift util tools"),
        (2, "swift-argument-parser"),
        (3, "util swift helper"),
        (4, "other-file"),
    ])

    let results = matchItems(matcher: matcher, pattern: "swift util", set: set)

    #expect(results.count >= 2)
    #expect(results.contains { set.text(of: $0.item) == "swift util tools" })
    #expect(results.contains { set.text(of: $0.item) == "swift-util-tools" })
}

@Test("Multiple spaces use backend split-space semantics")
func multipleWhitespaceTokens() {
    let matcher = FuzzyMatcher()

    #expect(matcher.match(pattern: "swift arg parser", text: "swift arg parser") != nil)
    #expect(matcher.match(pattern: "swift arg parser", text: "swift-argument-parser") != nil)
    #expect(matcher.match(pattern: "swift arg xyz", text: "swift-argument-parser") == nil)
}

@Test("Whitespace is not fltr-trimmed")
func whitespaceTrimmingAndEmpty() {
    let matcher = FuzzyMatcher()

    #expect(matcher.match(pattern: "  swift  ", text: "swift-file") == nil)
    #expect(matcher.match(pattern: "  swift  ", text: "  swift  ") != nil)

    #expect(matcher.match(pattern: "swift  util", text: "swift-util") != nil)
    #expect(matcher.match(pattern: "swift  util", text: "swift  util") != nil)

    // Whitespace-only query is no longer interpreted as empty query by fltr.
    let set = makeItems(["test"])
    let results = matchItems(matcher: matcher, pattern: "   ", set: set)
    #expect(results.count == 0)
}

@Test("FuzzyMatch backend enforces AND semantics for multi-word queries")
func fuzzyMatchBackendWhitespaceSemantics() {
    let matcher = FuzzyMatcher()
    #expect(matcher.match(pattern: "abc def", text: "xxabc_yydef_zz") != nil)
    #expect(matcher.match(pattern: "abc def", text: "abc def") != nil)
    #expect(matcher.match(pattern: "abc def", text: "xxabc_only_zz") == nil)
    #expect(matcher.match(pattern: "abc def", text: "yydef_only_zz") == nil)
}

@Test("FuzzyMatch backend rank/highlight paths follow delegated whitespace semantics")
func fuzzyMatchBackendRankAndHighlightWhitespace() {
    let matcher = FuzzyMatcher()

    let both = matchRankAndHighlight(matcher: matcher, query: "abc def", text: "00abc def00")
    #expect(both.0 != nil)
    #expect(both.1 != nil)
    #expect(!(both.1?.positions.isEmpty ?? true))

    let missing = matchRankAndHighlight(matcher: matcher, query: "abc def", text: "00abcxx000")
    #expect(missing.0 == nil)
    #expect(missing.1 == nil)
}

@Test("FuzzyMatch backend collapses repeated spaces between atoms")
func fuzzyMatchBackendMultipleSpacesLiteral() {
    let matcher = FuzzyMatcher()
    #expect(matcher.match(pattern: "abc   def", text: "abc...def") != nil)
    #expect(matcher.match(pattern: "abc   def", text: "abc   def") != nil)
    #expect(matcher.match(pattern: "abc   def", text: "abc...ghi") == nil)
}

@Test("Whitespace atoms match FormValidation-style camel case candidate")
func whitespaceAtomsMatchFormValidationCandidate() {
    let matcher = FuzzyMatcher()
    let text = "github.com/ainame/FormValidation"

    #expect(matcher.match(pattern: "form vali", text: text) != nil)

    let (rank, highlight) = matchRankAndHighlight(matcher: matcher, query: "form vali", text: text)
    #expect(rank != nil)
    #expect(highlight != nil)
    #expect(!(highlight?.positions.isEmpty ?? true))
}

// MARK: - Blackbox Integration Tests

@Test("Realistic file path matching - exact matches score highest")
func filePathExactMatching() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "README.md"),
        (1, "src/lib/readme/parser.md"),
        (2, "docs/read_me_first.md"),
        (3, "tests/reader_model_demo.md"),
    ])

    let results = matchItems(matcher: matcher, pattern: "README.md", set: set)

    // Should match multiple items but exact match scores highest
    #expect(results.count >= 1)
    #expect(set.text(of: results[0].item) == "README.md", "Exact match should be first")
}

@Test("Realistic file path matching - LICENSE files")
func filePathLICENSE() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "LICENSE"),
        (1, "LICENSE.md"),
        (2, "LICENSE.txt"),
        (3, "lib/license_checker.rb"),
        (4, "src/licensing/models.py"),
        (5, "docs/licensing_guide.md"),
    ])

    let results = matchItems(matcher: matcher, pattern: "LICENSE", set: set)

    // All LICENSE* files should match and rank higher than lib/licensing
    #expect(results.count >= 3)
    let topThree = results.prefix(3).map { set.text(of: $0.item) }
    #expect(topThree.contains("LICENSE"))
    #expect(topThree.contains("LICENSE.md"))
    #expect(topThree.contains("LICENSE.txt"))
}

@Test("Path matching - source files in nested directories")
func pathMatchingNested() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "main.swift"),
        (1, "src/main.swift"),
        (2, "tests/main_test.swift"),
        (3, "lib/utils/main_helper.swift"),
        (4, "src/domain/user/main.swift"),
    ])

    let results = matchItems(matcher: matcher, pattern: "main.swift", set: set)

    // All should match, but files named exactly "main.swift" should rank higher
    #expect(results.count >= 3)

    // First results should be exact filename matches
    let firstResult = set.text(of: results[0].item)
    #expect(firstResult == "main.swift" || firstResult == "src/main.swift" || firstResult == "src/domain/user/main.swift")
}

@Test("CamelCase matching - bonus for word boundaries")
func camelCaseMatching() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "UIViewController.swift"),
        (1, "UserInterfaceViewController.swift"),
        (2, "ui_view_controller.swift"),
        (3, "utils/ui/view/controller.swift"),
    ])

    let results = matchItems(matcher: matcher, pattern: "UIVC", set: set)

    // Should match camelCase and snake_case
    #expect(results.count >= 2)

    // UIViewController should score highly due to consecutive uppercase matches
    let topResults = results.prefix(2).map { set.text(of: $0.item) }
    #expect(topResults.contains("UIViewController.swift"))
}

@Test("Extension matching")
func extensionMatching() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "app.js"),
        (1, "app.json"),
        (2, "app.jsx"),
        (3, "application.js"),
    ])

    let results = matchItems(matcher: matcher, pattern: ".js", set: set)

    // Should match .js and .jsx files
    #expect(results.count >= 2)
    #expect(results.contains { set.text(of: $0.item) == "app.js" })
    #expect(results.contains { set.text(of: $0.item) == "application.js" })
}

@Test("Result ordering - consecutive matches score higher")
func consecutiveMatchBonus() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "test_file.txt"),        // "test" consecutive
        (1, "t_e_s_t_file.txt"),     // "test" spread out
        (2, "testing_file.txt"),     // "test" consecutive + more
    ])

    let results = matchItems(matcher: matcher, pattern: "test", set: set)

    #expect(results.count == 3)

    // All items should match, verify they're sorted by score
    if results.count >= 2 {
        #expect(results[0].score >= results[1].score, "Results should be sorted by score")
        #expect(results[1].score >= results[2].score, "Results should be sorted by score")
    }

    // At least verify consecutive match is in top results
    let topTwo = results.prefix(2).map { set.text(of: $0.item) }
    #expect(topTwo.contains("test_file.txt") || topTwo.contains("testing_file.txt"),
            "Consecutive matches should rank in top results")
}

@Test("Result ordering - earlier matches score higher")
func earlyMatchBonus() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "app.js"),
        (1, "src/app.js"),
        (2, "src/components/admin/app.js"),
    ])

    let results = matchItems(matcher: matcher, pattern: "app", set: set)

    #expect(results.count == 3)

    // "app.js" should rank higher than deeply nested paths
    let first = set.text(of: results[0].item)
    #expect(first == "app.js" || first == "src/app.js",
            "Shorter paths with earlier matches should rank higher")
}

// MARK: - Incremental Filtering Tests

@Test("Incremental filtering - extending query refines results")
func incrementalFilteringBasic() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "main.swift"),
        (1, "main_test.swift"),
        (2, "utils.swift"),
        (3, "config.json"),
    ])

    // First query: "ma"
    let results1 = matchItems(matcher: matcher, pattern: "ma", set: set)
    #expect(results1.count == 2, "'main' files should match 'ma'")

    // Extended query: "main"
    let results2 = matchItems(matcher: matcher, pattern: "main", set: set)
    #expect(results2.count == 2, "Both 'main' files should match")
    #expect(results2.allSatisfy { set.text(of: $0.item).contains("main") })

    // Further extension: "main.s"
    let results3 = matchItems(matcher: matcher, pattern: "main.s", set: set)
    #expect(results3.count >= 1)
    #expect(set.text(of: results3[0].item) == "main.swift", "Best match should be first")

    // Verify refinement: each extension should produce fewer or equal results
    #expect(results2.count <= results1.count, "Extending query should refine results")
    #expect(results3.count <= results2.count, "Further extension should further refine")
}

@Test("Incremental filtering - query extension maintains subset relationship")
func incrementalFilteringSubset() {
    let matcher = FuzzyMatcher()
    // Build a shared buffer for all 103 items
    let buffer = TextBuffer()
    var allItems: [Item] = []
    for i in 0..<100 {
        let text = "file_\(i).txt"
        let (offset, length) = buffer.append(text)
        allItems.append(Item(index: Int32(i), offset: offset, length: length))
    }
    let specialTexts = ["special.txt", "special_case.txt", "very_special.txt"]
    for (j, text) in specialTexts.enumerated() {
        let (offset, length) = buffer.append(text)
        allItems.append(Item(index: Int32(100 + j), offset: offset, length: length))
    }

    // Query "sp" - should match "special" items
    let results1 = matchItems(matcher: matcher, pattern: "sp", items: allItems, buffer: buffer)
    let matched1 = Set(results1.map { $0.item.text(in: buffer) })

    // Extended query "spe" - results should be subset of "sp" results
    let results2 = matchItems(matcher: matcher, pattern: "spe", items: allItems, buffer: buffer)
    let matched2 = Set(results2.map { $0.item.text(in: buffer) })

    #expect(matched2.isSubset(of: matched1),
            "Extending query should produce subset of results")

    // Further extension "spec" - even smaller subset
    let results3 = matchItems(matcher: matcher, pattern: "spec", items: allItems, buffer: buffer)
    let matched3 = Set(results3.map { $0.item.text(in: buffer) })

    #expect(matched3.isSubset(of: matched2))
    #expect(matched3.count <= matched2.count)
}

@Test("Incremental filtering - backspace expands results")
func incrementalFilteringBackspace() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "test.js"),
        (1, "test.ts"),
        (2, "test.jsx"),
        (3, "test.tsx"),
        (4, "test.json"),
    ])

    // Specific query: "test.ts"
    let results1 = matchItems(matcher: matcher, pattern: "test.ts", set: set)
    #expect(results1.count >= 1)

    // Backspace to "test.t" - should match more
    let results2 = matchItems(matcher: matcher, pattern: "test.t", set: set)
    #expect(results2.count >= results1.count,
            "Shorter query should match same or more items")

    // Backspace to "test" - should match all test files
    let results3 = matchItems(matcher: matcher, pattern: "test", set: set)
    #expect(results3.count == 5, "All test files should match")
}

@Test("Incremental filtering sequence - hello-world query")
func incrementalFilteringHelloWorld() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "hello-world"),
        (1, "hello"),
        (2, "helium"),
        (3, "help"),
        (4, "hero"),
        (5, "halo"),
        (6, "world-hello"),
    ])

    let q1 = matchItems(matcher: matcher, pattern: "h",           set: set)
    let q2 = matchItems(matcher: matcher, pattern: "he",          set: set)
    let q3 = matchItems(matcher: matcher, pattern: "hel",         set: set)
    let q4 = matchItems(matcher: matcher, pattern: "hell",        set: set)
    let q5 = matchItems(matcher: matcher, pattern: "hello",       set: set)
    let q6 = matchItems(matcher: matcher, pattern: "hello-",      set: set)
    let q7 = matchItems(matcher: matcher, pattern: "hello-w",     set: set)
    let q8 = matchItems(matcher: matcher, pattern: "hello-world", set: set)

    let s1 = Set(q1.map { set.text(of: $0.item) })
    let s2 = Set(q2.map { set.text(of: $0.item) })
    let s3 = Set(q3.map { set.text(of: $0.item) })
    let s4 = Set(q4.map { set.text(of: $0.item) })
    let s5 = Set(q5.map { set.text(of: $0.item) })
    let s6 = Set(q6.map { set.text(of: $0.item) })
    let s7 = Set(q7.map { set.text(of: $0.item) })
    let s8 = Set(q8.map { set.text(of: $0.item) })

    #expect(s2.isSubset(of: s1))
    #expect(s3.isSubset(of: s2))
    #expect(s4.isSubset(of: s3))
    #expect(s5.isSubset(of: s4))
    #expect(s6.isSubset(of: s5))
    #expect(s7.isSubset(of: s6))
    #expect(s8.isSubset(of: s7))

    #expect(q8.first.map { set.text(of: $0.item) } == "hello-world")
}

// MARK: - Edge Cases and Special Characters

@Test("Special characters in paths")
func specialCharactersInPaths() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "my-app/src/index.js"),
        (1, "my_app/src/index.js"),
        (2, "my.app/src/index.js"),
        (3, "my app/src/index.js"),
    ])

    let results = matchItems(matcher: matcher, pattern: "myapp", set: set)

    // Should match all variations
    #expect(results.count == 4, "Should match across delimiters")
}

@Test("Numbers in filenames")
func numbersInFilenames() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "v1.2.3/package.json"),
        (1, "v2.0.0/package.json"),
        (2, "version_1_2_3.txt"),
    ])

    let results = matchItems(matcher: matcher, pattern: "v123", set: set)

    #expect(results.count >= 1)
    #expect(results.contains { set.text(of: $0.item).contains("v1.2.3") || set.text(of: $0.item).contains("1_2_3") })
}

@Test("Very long paths")
func veryLongPaths() {
    let matcher = FuzzyMatcher()
    let longPath = "src/very/deeply/nested/directory/structure/with/many/levels/and/components/that/keeps/going/deeper/and/deeper/until/finally/target.swift"
    let set = makeItems([
        (0, longPath),
        (1, "target.swift"),
    ])

    let results = matchItems(matcher: matcher, pattern: "target", set: set)

    #expect(results.count == 2)
    // Shorter path should rank higher
    #expect(set.text(of: results[0].item) == "target.swift")
}

@Test("Empty and whitespace-only items")
func emptyItems() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, ""),
        (1, "   "),
        (2, "test"),
    ])

    let results = matchItems(matcher: matcher, pattern: "test", set: set)

    #expect(results.count == 1)
    #expect(set.text(of: results[0].item) == "test")
}

@Test("Case sensitivity comparison")
func caseSensitivityComparison() {
    let caseSensitive = FuzzyMatcher(caseSensitive: true)
    let caseInsensitive = FuzzyMatcher(caseSensitive: false)

    let set = makeItems([
        (0, "README.md"),
        (1, "readme.md"),
        (2, "ReadMe.md"),
    ])

    let sensitiveResults = matchItems(matcher: caseSensitive, pattern: "readme", set: set)
    let insensitiveResults = matchItems(matcher: caseInsensitive, pattern: "readme", set: set)

    // Case insensitive should match all
    #expect(insensitiveResults.count == 3)

    // Case sensitive should only match exact case
    #expect(sensitiveResults.count == 1)
    #expect(set.text(of: sensitiveResults[0].item) == "readme.md")
}

// MARK: - Performance and Scale Tests

@Test("Large result set maintains correct ordering")
func largeResultSetOrdering() {
    let matcher = FuzzyMatcher()

    // Build all items in one shared buffer
    let buffer = TextBuffer()
    var allItems: [Item] = []

    let bestText = "test.swift"
    let (o0, l0) = buffer.append(bestText)
    allItems.append(Item(index: 0, offset: o0, length: l0))

    let goodText = "test_utils.swift"
    let (o1, l1) = buffer.append(goodText)
    allItems.append(Item(index: 1, offset: o1, length: l1))

    // Add many mediocre matches
    for i in 2..<1000 {
        let text = "src/components/testing_file_\(i).swift"
        let (off, len) = buffer.append(text)
        allItems.append(Item(index: Int32(i), offset: off, length: len))
    }

    let results = matchItems(matcher: matcher, pattern: "test", items: allItems, buffer: buffer)

    // Should match many items
    #expect(results.count >= 100)

    // Verify results are sorted by score (descending)
    if results.count >= 10 {
        for i in 0..<(results.count - 1) {
            #expect(results[i].score >= results[i + 1].score,
                    "Results should be sorted by score descending")
        }
    }

    // Best matches should be in top results (top 10 is reasonable)
    let topTen = results.prefix(10).map { $0.item.text(in: buffer) }
    #expect(topTen.contains(where: { $0 == "test.swift" }), "Best match should be in top 10 even in large set")
    #expect(topTen.contains(where: { $0 == "test_utils.swift" }), "Good matches should be in top 10")
}

@Test("Common real-world query patterns")
func realWorldQueryPatterns() {
    let matcher = FuzzyMatcher()
    let set = makeItems([
        (0, "src/main/java/com/example/UserController.java"),
        (1, "src/main/java/com/example/UserService.java"),
        (2, "src/main/java/com/example/user/UserRepository.java"),
        (3, "src/test/java/com/example/UserControllerTest.java"),
    ])

    // Pattern: searching for specific class
    let results1 = matchItems(matcher: matcher, pattern: "UserController", set: set)
    #expect(results1.count >= 1)
    #expect(set.text(of: results1[0].item).contains("UserController.java"))

    // Pattern: query containing whitespace follows backend semantics.
    let results2 = matchItems(matcher: matcher, pattern: "test User", set: set)
    #expect(results2.count >= 1)
    #expect(results2.contains { set.text(of: $0.item).contains("UserControllerTest.java") })

    // Pattern: abbreviation
    let results3 = matchItems(matcher: matcher, pattern: "UC", set: set)
    #expect(results3.count >= 1)
    #expect(set.text(of: results3[0].item).contains("UserController"))
}

// MARK: - Scope Reduction Regression Tests
// These exercise the edges of the scopeIndices window logic introduced in the
// asciiFuzzyIndex optimisation.  Scores must be identical to a naive full-matrix
// run for the same inputs.

@Test("Scope reduction — single char match at start of string")
func scopeSingleCharAtStart() {
    let matcher = FuzzyMatcher()
    // 'a' appears only at index 0; scope window should be [0, 0]
    let result = matcher.match(pattern: "a", text: "abcdefghij")
    #expect(result != nil)
    #expect(result!.positions == [0] as [UInt16])
}

@Test("Scope reduction — single char match at end of string")
func scopeSingleCharAtEnd() {
    let matcher = FuzzyMatcher()
    // 'z' appears only at the very end
    let result = matcher.match(pattern: "z", text: "abcdefghijklmnopqrstuvwxyz")
    #expect(result != nil)
    #expect(result!.positions == [25] as [UInt16])
}

@Test("Scope reduction — single char match in middle, multiple occurrences")
func scopeSingleCharMultiple() {
    let matcher = FuzzyMatcher()
    // 'o' appears at indices 1, 4, 7 in "foo_boo_zoo"
    // The backward scan should widen the window to cover all three;
    // the DP picks the highest-scoring one (after delimiter at index 8).
    let result = matcher.match(pattern: "o", text: "foo_boo_zoo")
    #expect(result != nil)
    // Any valid 'o' position is acceptable; just verify it matched
    #expect(result!.positions.count == 1)
    let pos = result!.positions[0]
    #expect(pos == 1 || pos == 2 || pos == 4 || pos == 5 || pos == 8 || pos == 9 || pos == 10)
}

@Test("Scope reduction — multi-char pattern, match only at end")
func scopeMultiCharAtEnd() {
    let matcher = FuzzyMatcher()
    // "xyz" only at the tail
    let text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaxyz"
    let result = matcher.match(pattern: "xyz", text: text)
    #expect(result != nil)
    #expect(result!.positions.count == 3)
    // positions should be the last three bytes
    let len = text.utf8.count
    #expect(result!.positions == [UInt16(len - 3), UInt16(len - 2), UInt16(len - 1)])
}

@Test("Scope reduction — multi-char pattern, match only at start")
func scopeMultiCharAtStart() {
    let matcher = FuzzyMatcher()
    let text = "abczzzzzzzzzzzzzzzzzzzzzzzzz"
    let result = matcher.match(pattern: "abc", text: text)
    #expect(result != nil)
    #expect(result!.positions == [0, 1, 2] as [UInt16])
}

@Test("Scope reduction — score stability: word-boundary bonus preserved")
func scopeScoreStability() {
    let matcher = FuzzyMatcher()
    // "fb" in "foo_bar" should get delimiter bonus on 'b' (after '_').
    // Verify the score is positive and higher than the no-bonus case.
    let r1 = matcher.match(pattern: "fb", text: "foo_bar")
    let r2 = matcher.match(pattern: "fb", text: "foobar")
    #expect(r1 != nil)
    #expect(r2 != nil)
    #expect(r1!.score > r2!.score, "delimiter bonus must survive scope clamping")
}

@Test("Scope reduction — case-insensitive backward scan finds uppercase")
func scopeCaseInsensitiveBackward() {
    let matcher = FuzzyMatcher(caseSensitive: false)
    // Pattern 'a' (lowercase); text has 'A' only at the end.
    // The backward scan must match 'A' as an occurrence of 'a'.
    let result = matcher.match(pattern: "a", text: "bcdefghijklmnopqrstuvwxyzA")
    #expect(result != nil)
    // Should match the 'A' at the end (index 25) — it's the only 'a'/'A'
    #expect(result!.positions == [25] as [UInt16])
}

@Test("Scope reduction — long path, pattern scattered")
func scopeLongPathScattered() {
    let matcher = FuzzyMatcher()
    let text = "src/components/authentication/handlers/validate_token.swift"
    // "svt" — 's' near start, 'v' in validate, 't' in token/swift
    let result = matcher.match(pattern: "svt", text: text)
    #expect(result != nil)
    #expect(result!.positions.count == 3)
    // Positions must be strictly ascending
    #expect(result!.positions[0] < result!.positions[1])
    #expect(result!.positions[1] < result!.positions[2])
}

// MARK: - ChunkCache Unit Tests

/// Helper: build a result set of the given size with synthetic items.
/// Returns the results and the backing buffer (kept alive for the lifetime
/// of the returned array).
private func syntheticResults(_ count: Int, prefix: String = "item") -> ([MatchedItem], TextBuffer) {
    let buffer = TextBuffer()
    let results = (0..<count).map { i -> MatchedItem in
        let text = "\(prefix)_\(i)"
        let (offset, length) = buffer.append(text)
        let item = Item(index: Int32(i), offset: offset, length: length)
        return MatchedItem(item: item, matchResult: MatchResult(score: count - i, positions: [i]), points: 0)
    }
    return (results, buffer)
}

@Test("ChunkCache — add and exact lookup")
func chunkCacheAddLookup() {
    let cache = ChunkCache()
    let (results, _) = syntheticResults(5)

    // Store into a full chunk (chunkCount == Chunk.capacity)
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "ab", results: results)

    // Exact hit
    let hit = cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "ab")
    #expect(hit != nil)
    #expect(hit!.count == 5)

    // Miss on wrong query
    #expect(cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "ac") == nil)

    // Miss on wrong chunk index
    #expect(cache.lookup(chunkIndex: 1, chunkCount: Chunk.capacity, query: "ab") == nil)
}

@Test("ChunkCache — partial chunk is never cached")
func chunkCachePartialChunkGuard() {
    let cache = ChunkCache()
    let (results, _) = syntheticResults(3)

    // chunkCount < Chunk.capacity → add is a no-op
    cache.add(chunkIndex: 0, chunkCount: 42, query: "x", results: results)
    #expect(cache.lookup(chunkIndex: 0, chunkCount: 42, query: "x") == nil)

    // lookup also returns nil for partial chunks even if data were somehow present
    #expect(cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "x") == nil)
}

@Test("ChunkCache — selectivity gate drops high-count results")
func chunkCacheSelectivityGate() {
    let cache = ChunkCache()

    // Exactly at the gate (queryCacheMax == 20) — should be stored
    let (atGate, _) = syntheticResults(ChunkCache.queryCacheMax)
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "a", results: atGate)
    #expect(cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "a") != nil)

    // One over the gate — should be silently dropped
    let (overGate, _) = syntheticResults(ChunkCache.queryCacheMax + 1)
    cache.add(chunkIndex: 1, chunkCount: Chunk.capacity, query: "b", results: overGate)
    #expect(cache.lookup(chunkIndex: 1, chunkCount: Chunk.capacity, query: "b") == nil)
}

@Test("ChunkCache — empty query is never cached or looked up")
func chunkCacheEmptyQuery() {
    let cache = ChunkCache()
    let (r, _) = syntheticResults(1)
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "", results: r)
    #expect(cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "") == nil)
}

@Test("ChunkCache — search finds prefix sub-key")
func chunkCacheSearchPrefix() {
    let cache = ChunkCache()
    let (narrowResults, _) = syntheticResults(3, prefix: "narrow")

    // Cache results for "ab" (a prefix of "abc")
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "ab", results: narrowResults)

    // search("abc") should find "ab" as a prefix hit
    let hit = cache.search(chunkIndex: 0, chunkCount: Chunk.capacity, query: "abc")
    #expect(hit != nil)
    #expect(hit!.count == 3)
}

@Test("ChunkCache — search finds suffix sub-key")
func chunkCacheSearchSuffix() {
    let cache = ChunkCache()
    let (narrowResults, _) = syntheticResults(2, prefix: "sfx")

    // Cache results for "bc" (a suffix of "abc")
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "bc", results: narrowResults)

    // search("abc") should find "bc" as a suffix hit
    let hit = cache.search(chunkIndex: 0, chunkCount: Chunk.capacity, query: "abc")
    #expect(hit != nil)
    #expect(hit!.count == 2)
}

@Test("ChunkCache — search prefers longer sub-key over shorter")
func chunkCacheSearchLongestFirst() {
    let cache = ChunkCache()

    // Cache "a" (1 char) and "ab" (2 chars) for the same chunk
    let (shortR, _) = syntheticResults(10, prefix: "short")
    let (longR,  _) = syntheticResults(4,  prefix: "long")
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "a",  results: shortR)
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "ab", results: longR)

    // search("abc") tries prefixes longest-first: "ab" before "a"
    let hit = cache.search(chunkIndex: 0, chunkCount: Chunk.capacity, query: "abc")
    #expect(hit != nil)
    #expect(hit!.count == 4, "Should return the longer (more selective) cached set")
}

@Test("ChunkCache — search returns nil when no sub-key cached")
func chunkCacheSearchMiss() {
    let cache = ChunkCache()
    // Nothing cached at all
    #expect(cache.search(chunkIndex: 0, chunkCount: Chunk.capacity, query: "xyz") == nil)

    // Cache something on a different chunk
    let (r, _) = syntheticResults(1)
    cache.add(chunkIndex: 5, chunkCount: Chunk.capacity, query: "xy", results: r)
    #expect(cache.search(chunkIndex: 0, chunkCount: Chunk.capacity, query: "xyz") == nil)
}

@Test("ChunkCache — clear wipes all entries")
func chunkCacheClear() {
    let cache = ChunkCache()
    let (r1, _) = syntheticResults(1)
    let (r2, _) = syntheticResults(2)
    cache.add(chunkIndex: 0, chunkCount: Chunk.capacity, query: "a", results: r1)
    cache.add(chunkIndex: 1, chunkCount: Chunk.capacity, query: "b", results: r2)

    #expect(cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "a") != nil)

    cache.clear()

    #expect(cache.lookup(chunkIndex: 0, chunkCount: Chunk.capacity, query: "a") == nil)
    #expect(cache.lookup(chunkIndex: 1, chunkCount: Chunk.capacity, query: "b") == nil)
}

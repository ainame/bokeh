import Foundation
import Testing
@testable import FltrLib

@Test("UI selection with headless terminal")
func uiSelectionWithTestTerminal() async throws {
    let cache = ItemCache()
    await cache.append("apple")
    await cache.append("apricot")
    await cache.append("banana")

    let reader = StdinReader(cache: cache)
    await reader.finishReading()

    let terminal = TestTerminal(rows: 12, cols: 40)
    let matcher = FuzzyMatcher(caseSensitive: false)
    let ui = UIController(
        terminal: terminal,
        matcher: matcher,
        cache: cache,
        reader: reader,
        maxHeight: nil,
        multiSelect: false,
        previewCommand: nil,
        useFloatingPreview: false,
        debounceDelay: .milliseconds(10)
    )

    let runTask = Task { try await ui.run() }

    await terminal.enqueue(bytes: Array("ap".utf8))
    try await Task.sleep(for: .milliseconds(30))
    await terminal.enqueue(bytes: [27, 91, 66])  // Down arrow
    try await Task.sleep(for: .milliseconds(10))
    await terminal.enqueue(bytes: [13])  // Enter

    let selected = try await runTask.value
    #expect(selected.count == 1)
    #expect(selected[0].text(in: cache.buffer) == "apricot")

    let output = await terminal.output
    #expect(output.contains("ap"))
}

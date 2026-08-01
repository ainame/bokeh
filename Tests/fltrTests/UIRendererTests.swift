import Testing
@testable import FltrLib

@Test("Renderer anchors terminal cursor at prompt caret")
func rendererAnchorsCursorAtPromptCaret() {
    var state = UIState()
    state.query = "abc"
    state.cursorPosition = 3

    let renderer = UIRenderer(maxHeight: nil, multiSelect: false)
    let frame = renderer.assembleFrame(
        state: state,
        visibleItems: [],
        highlightPositions: [:],
        context: RenderContext(
            rows: 12,
            cols: 40,
            isReadingStdin: false,
            searchProgress: nil,
            showSplitPreview: false,
            showFloatingPreview: false,
            spinnerFrame: 0
        ),
        buffer: TextBuffer()
    )

    // "> " is 2 cells. Cursor at end of "abc" (3 cells) -> col 6.
    #expect(frame.hasSuffix("\u{001B}[1;6H"))
}

@Test("Renderer cursor anchor respects wide characters")
func rendererCursorAnchorWideChars() {
    var state = UIState()
    state.query = "あ"
    state.cursorPosition = 1

    let renderer = UIRenderer(maxHeight: nil, multiSelect: false)
    let frame = renderer.assembleFrame(
        state: state,
        visibleItems: [],
        highlightPositions: [:],
        context: RenderContext(
            rows: 12,
            cols: 40,
            isReadingStdin: false,
            searchProgress: nil,
            showSplitPreview: false,
            showFloatingPreview: false,
            spinnerFrame: 0
        ),
        buffer: TextBuffer()
    )

    // "> " is 2 cells. "あ" is 2 cells. Caret at end -> col 5.
    #expect(frame.hasSuffix("\u{001B}[1;5H"))
}

@Test("Renderer shows search progress while matching")
func rendererShowsSearchProgress() {
    let progress = SearchProgress(total: 500)
    progress.advance(by: 128)

    let renderer = UIRenderer(maxHeight: nil, multiSelect: false)
    let frame = renderer.assembleFrame(
        state: UIState(),
        visibleItems: [],
        highlightPositions: [:],
        context: RenderContext(
            rows: 12,
            cols: 80,
            isReadingStdin: false,
            searchProgress: progress.snapshot(),
            showSplitPreview: false,
            showFloatingPreview: false,
            spinnerFrame: 0
        ),
        buffer: TextBuffer()
    )

    #expect(frame.contains("[25%]"))
    #expect(frame.contains("\u{001B}[2;1H"))
}

@Test("Renderer keeps a fixed ready indicator beside the count")
func rendererShowsReadyTick() {
    let renderer = UIRenderer(maxHeight: nil, multiSelect: false)
    let frame = renderer.assembleFrame(
        state: UIState(),
        visibleItems: [],
        highlightPositions: [:],
        context: RenderContext(
            rows: 12,
            cols: 80,
            isReadingStdin: false,
            searchProgress: nil,
            showSplitPreview: false,
            showFloatingPreview: false,
            spinnerFrame: 0
        ),
        buffer: TextBuffer()
    )

    #expect(frame.contains("✓ 0/0"))
    #expect(frame.contains("\u{001B}[2;1H"))
}

@Test("Renderer uses a viewport scrollbar instead of a percentage")
func rendererUsesViewportScrollbar() {
    var state = UIState()
    state.matchCount = 100
    state.totalItems = 100

    let renderer = UIRenderer(maxHeight: nil, multiSelect: false)
    let context = RenderContext(
        rows: 12,
        cols: 40,
        isReadingStdin: false,
        searchProgress: nil,
        showSplitPreview: false,
        showFloatingPreview: false,
        spinnerFrame: 0
    )

    let topFrame = renderer.assembleFrame(
        state: state,
        visibleItems: [],
        highlightPositions: [:],
        context: context,
        buffer: TextBuffer()
    )
    #expect(topFrame.contains("\u{001B}[3;40H█"))
    #expect(!topFrame.contains("[0%]"))

    state.scrollOffset = 46  // Halfway through the 91-row scroll range.
    let middleFrame = renderer.assembleFrame(
        state: state,
        visibleItems: [],
        highlightPositions: [:],
        context: context,
        buffer: TextBuffer()
    )
    #expect(middleFrame.contains("\u{001B}[7;40H█"))

    state.scrollOffset = 91
    let bottomFrame = renderer.assembleFrame(
        state: state,
        visibleItems: [],
        highlightPositions: [:],
        context: context,
        buffer: TextBuffer()
    )
    #expect(bottomFrame.contains("\u{001B}[11;40H█"))

    state.matchCount = 8  // Fits exactly in the eight-row viewport.
    state.scrollOffset = 0
    let shortListFrame = renderer.assembleFrame(
        state: state,
        visibleItems: [],
        highlightPositions: [:],
        context: context,
        buffer: TextBuffer()
    )
    #expect(!shortListFrame.contains("│"))
    #expect(!shortListFrame.contains("█"))
}

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
            showSplitPreview: false,
            showFloatingPreview: false,
            spinnerFrame: 0
        ),
        buffer: TextBuffer()
    )

    // "> " is 2 cells. "あ" is 2 cells. Caret at end -> col 5.
    #expect(frame.hasSuffix("\u{001B}[1;5H"))
}


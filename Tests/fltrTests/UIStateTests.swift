import Testing
@testable import FltrLib

@Test("UIState cursor and delete operate on grapheme clusters")
func uiStateGraphemeEditing() {
    var state = UIState()

    state.addChar("あ")
    state.addChar("😊")
    state.addChar(Character("e\u{301}"))  // decomposed "é"

    #expect(state.query == "あ😊e\u{301}")
    #expect(state.query.count == 3)
    #expect(state.cursorPosition == 3)

    state.moveCursorLeft()
    #expect(state.cursorPosition == 2)
    state.deleteChar()
    #expect(state.query == "あe\u{301}")
    #expect(state.cursorPosition == 1)

    state.moveCursorToEnd()
    state.deleteChar()
    #expect(state.query == "あ")
    #expect(state.cursorPosition == 1)
}

import Testing
import TUI

@Test("InputDecoder decodes hiragana UTF-8 as one character")
func inputDecoderHiragana() {
    var decoder = InputDecoder()
    for byte in "あ".utf8 {
        decoder.feed(byte)
    }

    #expect(decoder.nextEvent() == .char("あ"))
    #expect(decoder.nextEvent() == nil)
}

@Test("InputDecoder decodes emoji UTF-8 as one character")
func inputDecoderEmoji() {
    var decoder = InputDecoder()
    for byte in "😊".utf8 {
        decoder.feed(byte)
    }

    #expect(decoder.nextEvent() == .char("😊"))
    #expect(decoder.nextEvent() == nil)
}

@Test("InputDecoder reports unknown on invalid UTF-8 continuation")
func inputDecoderInvalidUTF8() {
    var decoder = InputDecoder()
    decoder.feed(0xE3)
    decoder.feed(0x28)  // invalid continuation

    #expect(decoder.nextEvent() == .unknown)
}

@Test("InputDecoder distinguishes standalone ESC and ESC sequences")
func inputDecoderEscapeHandling() {
    var decoder = InputDecoder()

    decoder.feed(27)
    #expect(decoder.nextEvent() == nil)
    decoder.handleTimeout()
    #expect(decoder.nextEvent() == .escape)

    decoder.feed(27)
    decoder.feed(91)
    decoder.feed(65)
    #expect(decoder.nextEvent() == .up)

    decoder.feed(27)
    decoder.feed(118)
    #expect(decoder.nextEvent() == .altV)
}

@Test("InputDecoder parses SGR mouse scroll")
func inputDecoderMouseScroll() {
    var decoder = InputDecoder()
    for byte in "\u{001B}[<64;12;3M".utf8 {
        decoder.feed(byte)
    }

    #expect(decoder.nextEvent() == .mouseScrollUp(col: 12, row: 3))
}

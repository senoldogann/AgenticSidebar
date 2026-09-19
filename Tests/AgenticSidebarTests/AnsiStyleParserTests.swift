import AppKit
import XCTest

@testable import AgenticSidebar

/// ANSI renk/biçim ayrıştırıcısının saf testleri.
///
/// Dosyada görünmez bayt olmasın diye ESC/BEL sayısal kurulur; hiçbir dize
/// kaçış içermez.
final class AnsiStyleParserTests: XCTestCase {
    private let esc = String(UnicodeScalar(0x1B)!)
    private let bel = String(UnicodeScalar(0x07)!)

    private func sequence(_ body: String) -> String {
        esc + "[" + body
    }

    private func attributes(in styled: NSAttributedString, at location: Int = 0) -> [NSAttributedString.Key: Any] {
        styled.attributes(at: location, effectiveRange: nil)
    }

    private func foreground(in styled: NSAttributedString, at location: Int = 0) -> NSColor? {
        attributes(in: styled, at: location)[.foregroundColor] as? NSColor
    }

    func testPlainTextKeepsLabelColorAndBaseFont() {
        let styled = AnsiStyleParser.styled("hello")

        XCTAssertEqual(styled.string, "hello")
        let attrs = attributes(in: styled)
        XCTAssertEqual((attrs[.font] as? NSFont), AnsiStyleParser.baseFont())
        XCTAssertEqual(foreground(in: styled), NSColor.labelColor)
    }

    func testRedTextAndReset() {
        let styled = AnsiStyleParser.styled(sequence("31m") + "red" + sequence("0m") + "plain")

        XCTAssertEqual(styled.string, "redplain")
        let red = foreground(in: styled, at: 0)
        XCTAssertEqual(red?.redComponent ?? -1, 0.804, accuracy: 0.01)
        XCTAssertEqual(red?.greenComponent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(foreground(in: styled, at: 3), NSColor.labelColor)
    }

    func testBoldSetsTheBoldTrait() {
        let styled = AnsiStyleParser.styled(sequence("1m") + "bold")

        let font = attributes(in: styled)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testBrightForegroundAndBackground() {
        let styled = AnsiStyleParser.styled(
            sequence("92m") + "green" + sequence("0m") + sequence("44m") + "bg"
        )

        XCTAssertEqual(styled.string, "greenbg")
        XCTAssertEqual(foreground(in: styled, at: 0)?.greenComponent ?? -1, 1, accuracy: 0.01)
        let background = attributes(in: styled, at: 5)[.backgroundColor] as? NSColor
        XCTAssertEqual(background?.blueComponent ?? -1, 0.804, accuracy: 0.01)
    }

    func test256ColorAndTruecolor() {
        let palette = AnsiStyleParser.styled(sequence("38;5;196m") + "x")
        XCTAssertEqual(foreground(in: palette)?.redComponent ?? -1, 1, accuracy: 0.01)

        let rgb = AnsiStyleParser.styled(sequence("38;2;10;20;30m") + "y")
        let color = foreground(in: rgb)
        XCTAssertEqual(color?.redComponent ?? -1, 10.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(color?.greenComponent ?? -1, 20.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(color?.blueComponent ?? -1, 30.0 / 255.0, accuracy: 0.01)
    }

    func testNonSGRSequencesAreDropped() {
        let styled = AnsiStyleParser.styled(
            "a" + sequence("?25l") + "b" + sequence("K") + "c" + sequence("2J") + "d"
        )

        XCTAssertEqual(styled.string, "abcd")
    }

    func testBareResetClearsTheStyle() {
        let styled = AnsiStyleParser.styled(sequence("31m") + "red" + sequence("m") + "plain")

        XCTAssertEqual(styled.string, "redplain")
        XCTAssertEqual(foreground(in: styled, at: 3), NSColor.labelColor)
    }

    func testOscHyperlinkIsDropped() {
        let styled = AnsiStyleParser.styled("a" + esc + "]8;;https://example.com" + bel + "b")

        XCTAssertEqual(styled.string, "ab")
    }

    /// Kaçış dizisi metin eklemeden tüketilir: SGR biçimi günceller, SGR
    /// olmayan dizi (`ESC[K` gibi) biçimi bozmadan çöpe gider.
    func testConsumeEscapeSequenceUpdatesStyleWithoutAppending() {
        var parser = AnsiStyleParser()
        let result = NSMutableAttributedString()
        parser.consumeEscapeSequence(sequence("31m"))
        parser.consumeEscapeSequence(sequence("K"))
        parser.append("red", to: result)

        XCTAssertEqual(result.string, "red")
        let red = attributes(in: result)[.foregroundColor] as? NSColor
        XCTAssertEqual(red?.redComponent ?? -1, 0.804, accuracy: 0.01)
    }

    func testStyleStateSpansAppends() {
        var parser = AnsiStyleParser()
        let result = NSMutableAttributedString()
        parser.append(sequence("31m"), to: result)
        parser.append("red", to: result)

        XCTAssertEqual(result.string, "red")
        let red = attributes(in: result)[.foregroundColor] as? NSColor
        XCTAssertEqual(red?.redComponent ?? -1, 0.804, accuracy: 0.01)
    }

    func testTrailingPartialEscapeWaitsForTheNextChunk() {
        let split = AnsiStyleParser.splitTrailingPartialEscape("foo" + esc + "[3")

        XCTAssertEqual(split.complete, "foo")
        XCTAssertEqual(split.pending, esc + "[3")

        var parser = AnsiStyleParser()
        let result = NSMutableAttributedString()
        parser.append(split.complete, to: result)
        parser.append(split.pending + "1m" + "red", to: result)

        XCTAssertEqual(result.string, "foored")
        let red = (result.attributes(at: 3, effectiveRange: nil)[.foregroundColor] as? NSColor)
        XCTAssertEqual(red?.redComponent ?? -1, 0.804, accuracy: 0.01)
    }

    func testCompleteTrailingEscapeIsNotHeld() {
        let split = AnsiStyleParser.splitTrailingPartialEscape("foo" + sequence("0m"))

        XCTAssertEqual(split.pending, "")
        XCTAssertEqual(split.complete, "foo" + sequence("0m"))
    }
}

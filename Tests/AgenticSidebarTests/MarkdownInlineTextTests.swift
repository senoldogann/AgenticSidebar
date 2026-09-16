import Foundation
import XCTest
@testable import AgenticSidebar

final class MarkdownInlineTextTests: XCTestCase {
    func testEmphasisAndCodeSpansKeepTheirPresentationIntent() throws {
        let attributed = MarkdownInlineText.attributed(
            from: "Use `swift build` for **bold** and *italic* text."
        )

        XCTAssertEqual(String(attributed.characters), "Use swift build for bold and italic text.")

        let intents = attributed.runs.compactMap { $0.inlinePresentationIntent }
        XCTAssertTrue(intents.contains(.code), "Code spans keep their presentation intent")
        XCTAssertTrue(intents.contains(.stronglyEmphasized))
        XCTAssertTrue(intents.contains(.emphasized))
    }

    /// `Text(LocalizedStringKey(_:))` treats the message as a localization key and
    /// as a format string; user content must not be either.
    func testLiteralContentSurvivesPercentSignsAndPlaceholders() {
        let text = "Coverage is 100% and the token is %@ plus [[placeholder]]."

        let attributed = MarkdownInlineText.attributed(from: text)

        XCTAssertEqual(String(attributed.characters), text)
    }

    func testMalformedMarkdownFallsBackToLiteralText() {
        let text = "An unclosed **emphasis and `a code span"

        let attributed = MarkdownInlineText.attributed(from: text)

        XCTAssertEqual(String(attributed.characters), text)
    }

    func testPlainTextIsUnchanged() {
        let attributed = MarkdownInlineText.attributed(from: "Just a sentence.")

        XCTAssertEqual(String(attributed.characters), "Just a sentence.")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }
}

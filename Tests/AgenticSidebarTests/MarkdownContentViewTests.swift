import XCTest
@testable import AgenticSidebar

final class MarkdownContentViewTests: XCTestCase {
    func testParseMarkdownBlocksExtractsHeadingsCodeAndLists() {
        let sample = """
        # Title
        Here is a **bold** paragraph.

        ```swift
        let x = 10
        print(x)
        ```

        - First item
        - Second item

        > A blockquote

        1. Step one
        2. Step two
        """

        let blocks = parseMarkdownBlocks(from: sample)

        XCTAssertFalse(blocks.isEmpty)

        guard case let .heading(_, level, text) = blocks[0] else {
            XCTFail("Expected first block to be heading")
            return
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(text, "Title")

        guard case let .paragraph(_, content) = blocks[1] else {
            XCTFail("Expected second block to be paragraph")
            return
        }
        XCTAssertTrue(content.contains("**bold**"))

        guard case let .code(_, language, code) = blocks[2] else {
            XCTFail("Expected third block to be code block")
            return
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("let x = 10"))

        guard case let .bulletItem(_, item1) = blocks[3] else {
            XCTFail("Expected fourth block to be bullet item")
            return
        }
        XCTAssertEqual(item1, "First item")

        guard case let .bulletItem(_, item2) = blocks[4] else {
            XCTFail("Expected fifth block to be bullet item")
            return
        }
        XCTAssertEqual(item2, "Second item")

        guard case let .blockquote(_, quote) = blocks[5] else {
            XCTFail("Expected sixth block to be blockquote")
            return
        }
        XCTAssertEqual(quote, "A blockquote")

        guard case let .numberedItem(_, number1, step1) = blocks[6] else {
            XCTFail("Expected seventh block to be numbered item")
            return
        }
        XCTAssertEqual(number1, "1.")
        XCTAssertEqual(step1, "Step one")

        guard case let .numberedItem(_, number2, step2) = blocks[7] else {
            XCTFail("Expected eighth block to be numbered item")
            return
        }
        XCTAssertEqual(number2, "2.")
        XCTAssertEqual(step2, "Step two")
    }
}

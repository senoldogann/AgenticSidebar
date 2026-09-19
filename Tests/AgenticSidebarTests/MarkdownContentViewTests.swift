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

        guard case .heading(_, let level, let text) = blocks[0] else {
            XCTFail("Expected first block to be heading")
            return
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(text, "Title")

        guard case .paragraph(_, let content) = blocks[1] else {
            XCTFail("Expected second block to be paragraph")
            return
        }
        XCTAssertTrue(content.contains("**bold**"))

        guard case .code(_, let language, let code) = blocks[2] else {
            XCTFail("Expected third block to be code block")
            return
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("let x = 10"))

        guard case .bulletItem(_, let item1) = blocks[3] else {
            XCTFail("Expected fourth block to be bullet item")
            return
        }
        XCTAssertEqual(item1, "First item")

        guard case .bulletItem(_, let item2) = blocks[4] else {
            XCTFail("Expected fifth block to be bullet item")
            return
        }
        XCTAssertEqual(item2, "Second item")

        guard case .blockquote(_, let quote) = blocks[5] else {
            XCTFail("Expected sixth block to be blockquote")
            return
        }
        XCTAssertEqual(quote, "A blockquote")

        guard case .numberedItem(_, let number1, let step1) = blocks[6] else {
            XCTFail("Expected seventh block to be numbered item")
            return
        }
        XCTAssertEqual(number1, "1.")
        XCTAssertEqual(step1, "Step one")

        guard case .numberedItem(_, let number2, let step2) = blocks[7] else {
            XCTFail("Expected eighth block to be numbered item")
            return
        }
        XCTAssertEqual(number2, "2.")
        XCTAssertEqual(step2, "Step two")
    }
}

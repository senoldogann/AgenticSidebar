import XCTest
@testable import AgenticSidebar

final class MarkdownBlockParsingTests: XCTestCase {
    func testUnderscoreDividerTerminatesAParagraph() {
        let blocks = parseMarkdownBlocks(
            from: """
            First paragraph line
            ___
            Second paragraph
            """
        )

        XCTAssertEqual(blocks.count, 3)

        guard case let .paragraph(_, firstParagraph) = blocks[0] else {
            XCTFail("Expected a paragraph before the divider")
            return
        }
        XCTAssertEqual(firstParagraph, "First paragraph line")

        guard case .divider = blocks[1] else {
            XCTFail("Expected the underscore rule to render as a divider")
            return
        }

        guard case let .paragraph(_, secondParagraph) = blocks[2] else {
            XCTFail("Expected a paragraph after the divider")
            return
        }
        XCTAssertEqual(secondParagraph, "Second paragraph")
    }

    func testProseStartingWithAYearIsNotAnOrderedListItem() {
        let blocks = parseMarkdownBlocks(
            from: "2026. was a busy year for this project."
        )

        guard case let .paragraph(_, content) = blocks.first else {
            XCTFail("A four-digit prefix must stay prose")
            return
        }
        XCTAssertEqual(content, "2026. was a busy year for this project.")
    }

    func testShortOrderedListMarkersStillParse() {
        let blocks = parseMarkdownBlocks(
            from: """
            1. First step
            12. Twelfth step
            """
        )

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(numberedItem(from: blocks[0]), "1.")
        XCTAssertEqual(numberedItem(from: blocks[1]), "12.")
    }

    func testCodeFenceContentIsNotTreatedAsMarkdown() {
        let blocks = parseMarkdownBlocks(
            from: """
            ```swift
            let value = 42
            ```
            """
        )

        XCTAssertEqual(blocks.count, 1)
        guard case let .code(_, language, code) = blocks[0] else {
            XCTFail("Expected a code block")
            return
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let value = 42")
    }

    func testPipeTableParsesHeadersAlignmentAndRows() {
        let blocks = parseMarkdownBlocks(
            from: """
            | Name | Score | Rank |
            | :--- | :---: | ---: |
            | Ada | 98 | 1 |
            | Grace | 91 | 2 |
            """
        )

        XCTAssertEqual(blocks.count, 1)
        guard case let .table(_, headers, alignments, rows) = blocks[0] else {
            XCTFail("Expected a table block")
            return
        }

        XCTAssertEqual(headers, ["Name", "Score", "Rank"])
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        XCTAssertEqual(rows, [["Ada", "98", "1"], ["Grace", "91", "2"]])
    }

    func testTablePadsAndTrimsRowsToTheHeaderWidth() {
        let blocks = parseMarkdownBlocks(
            from: """
            | A | B |
            | --- | --- |
            | 1 |
            | 1 | 2 | 3 |
            """
        )

        guard case let .table(_, _, _, rows) = blocks.first else {
            XCTFail("Expected a table block")
            return
        }

        XCTAssertEqual(rows, [["1", ""], ["1", "2"]])
    }

    func testTableBreaksOutOfAParagraphAndEndsAtProse() {
        let blocks = parseMarkdownBlocks(
            from: """
            Intro line
            | A | B |
            | --- | --- |
            | 1 | 2 |
            After the table
            """
        )

        XCTAssertEqual(blocks.count, 3)

        guard case let .paragraph(_, intro) = blocks[0] else {
            XCTFail("Expected the intro to stay a paragraph")
            return
        }
        XCTAssertEqual(intro, "Intro line")

        guard case .table = blocks[1] else {
            XCTFail("Expected a table block")
            return
        }

        guard case let .paragraph(_, outro) = blocks[2] else {
            XCTFail("Expected the trailing prose to stay a paragraph")
            return
        }
        XCTAssertEqual(outro, "After the table")
    }

    func testPipesInProseWithoutADelimiterRowStayProse() {
        let blocks = parseMarkdownBlocks(from: "Use a | b for alternation")

        guard case let .paragraph(_, content) = blocks.first else {
            XCTFail("A lone pipe must not start a table")
            return
        }
        XCTAssertEqual(content, "Use a | b for alternation")
    }

    func testChartFenceParsesIntoAChartBlock() {
        let blocks = parseMarkdownBlocks(
            from: """
            ```chart
            type: line
            title: Revenue
            Q1 = 10
            Q2 = 22.5
            ```
            """
        )

        guard case let .chart(_, spec) = blocks.first else {
            XCTFail("Expected a chart block")
            return
        }

        XCTAssertEqual(spec.kind, .line)
        XCTAssertEqual(spec.title, "Revenue")
        XCTAssertEqual(
            spec.points,
            [
                MarkdownChartPoint(label: "Q1", value: 10),
                MarkdownChartPoint(label: "Q2", value: 22.5)
            ]
        )
    }

    func testChartFenceAcceptsLabelsAndValuesLists() {
        let blocks = parseMarkdownBlocks(
            from: """
            ```chart bar
            labels: Jan, Feb, Mar
            values: 3, 5, 8
            ```
            """
        )

        guard case let .chart(_, spec) = blocks.first else {
            XCTFail("Expected a chart block")
            return
        }

        XCTAssertEqual(spec.kind, .bar)
        XCTAssertEqual(spec.points.count, 3)
        XCTAssertEqual(spec.points[1], MarkdownChartPoint(label: "Feb", value: 5))
    }

    func testChartFenceWithoutDataStaysACodeBlock() {
        let blocks = parseMarkdownBlocks(
            from: """
            ```chart
            there is no series here
            ```
            """
        )

        guard case let .code(_, language, _) = blocks.first else {
            XCTFail("A malformed chart must fall back to a code block")
            return
        }
        XCTAssertEqual(language, "chart")
    }

    func testMathFenceAndBlockParsing() {
        let blocks = parseMarkdownBlocks(
            from: """
            The quadratic formula is:
            $$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$
            And in a code fence:
            ```math
            \\int_{0}^{\\infty} e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}
            ```
            """
        )

        XCTAssertEqual(blocks.count, 4)
        guard case let .paragraph(_, p1) = blocks[0] else {
            XCTFail("Expected first paragraph")
            return
        }
        XCTAssertTrue(p1.contains("quadratic formula"))

        guard case let .math(_, f1) = blocks[1] else {
            XCTFail("Expected first math block for $$ equation")
            return
        }
        XCTAssertTrue(f1.contains("\\frac{-b"))

        guard case let .paragraph(_, p2) = blocks[2] else {
            XCTFail("Expected second paragraph")
            return
        }
        XCTAssertTrue(p2.contains("code fence"))

        guard case let .math(_, f2) = blocks[3] else {
            XCTFail("Expected math block from ```math fence")
            return
        }
        XCTAssertTrue(f2.contains("e^{-x^2}"))
    }

    private func numberedItem(from block: MarkdownBlock) -> String? {
        guard case let .numberedItem(_, number, _) = block else {
            return nil
        }

        return number
    }
}

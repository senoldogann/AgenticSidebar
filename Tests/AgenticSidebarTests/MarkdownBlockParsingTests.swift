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

        guard case .paragraph(_, let firstParagraph) = blocks[0] else {
            XCTFail("Expected a paragraph before the divider")
            return
        }
        XCTAssertEqual(firstParagraph, "First paragraph line")

        guard case .divider = blocks[1] else {
            XCTFail("Expected the underscore rule to render as a divider")
            return
        }

        guard case .paragraph(_, let secondParagraph) = blocks[2] else {
            XCTFail("Expected a paragraph after the divider")
            return
        }
        XCTAssertEqual(secondParagraph, "Second paragraph")
    }

    func testProseStartingWithAYearIsNotAnOrderedListItem() {
        let blocks = parseMarkdownBlocks(
            from: "2026. was a busy year for this project."
        )

        guard case .paragraph(_, let content) = blocks.first else {
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
        guard case .code(_, let language, let code) = blocks[0] else {
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
        guard case .table(_, let headers, let alignments, let rows) = blocks[0] else {
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

        guard case .table(_, _, _, let rows) = blocks.first else {
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

        guard case .paragraph(_, let intro) = blocks[0] else {
            XCTFail("Expected the intro to stay a paragraph")
            return
        }
        XCTAssertEqual(intro, "Intro line")

        guard case .table = blocks[1] else {
            XCTFail("Expected a table block")
            return
        }

        guard case .paragraph(_, let outro) = blocks[2] else {
            XCTFail("Expected the trailing prose to stay a paragraph")
            return
        }
        XCTAssertEqual(outro, "After the table")
    }

    func testPipesInProseWithoutADelimiterRowStayProse() {
        let blocks = parseMarkdownBlocks(from: "Use a | b for alternation")

        guard case .paragraph(_, let content) = blocks.first else {
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

        guard case .chart(_, let spec) = blocks.first else {
            XCTFail("Expected a chart block")
            return
        }

        XCTAssertEqual(spec.kind, .line)
        XCTAssertEqual(spec.title, "Revenue")
        XCTAssertEqual(
            spec.points,
            [
                MarkdownChartPoint(label: "Q1", value: 10),
                MarkdownChartPoint(label: "Q2", value: 22.5),
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

        guard case .chart(_, let spec) = blocks.first else {
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

        guard case .code(_, let language, _) = blocks.first else {
            XCTFail("A malformed chart must fall back to a code block")
            return
        }
        XCTAssertEqual(language, "chart")
    }

    func testChartFenceWithUnknownKindStaysACodeBlock() {
        let blocks = parseMarkdownBlocks(
            from: """
                ```chart histogram
                labels: Jan, Feb
                values: 3, 5
                ```
                """
        )

        guard case .code(_, let language, _) = blocks.first else {
            XCTFail("An unknown chart kind must not silently become a bar chart")
            return
        }
        XCTAssertEqual(language, "chart histogram")
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
        guard case .paragraph(_, let p1) = blocks[0] else {
            XCTFail("Expected first paragraph")
            return
        }
        XCTAssertTrue(p1.contains("quadratic formula"))

        guard case .math(_, let f1) = blocks[1] else {
            XCTFail("Expected first math block for $$ equation")
            return
        }
        XCTAssertTrue(f1.contains("\\frac{-b"))

        guard case .paragraph(_, let p2) = blocks[2] else {
            XCTFail("Expected second paragraph")
            return
        }
        XCTAssertTrue(p2.contains("code fence"))

        guard case .math(_, let f2) = blocks[3] else {
            XCTFail("Expected math block from ```math fence")
            return
        }
        XCTAssertTrue(f2.contains("e^{-x^2}"))
    }

    func testUnclosedDisplayMathDoesNotSwallowTheRest() {
        var lines = ["$$ unclosed formula"]
        lines += (1...50).map { "filler line \($0)" }
        lines += ["```swift", "let rescued = true", "```"]
        let blocks = parseMarkdownBlocks(from: lines.joined(separator: "\n"))

        XCTAssertFalse(
            blocks.contains {
                if case .math = $0 { return true }
                return false
            },
            "An unclosed $$ must not become a math block"
        )
        XCTAssertTrue(
            blocks.contains {
                if case .code(_, let language, let code) = $0 {
                    return language == "swift" && code.contains("let rescued = true")
                }
                return false
            },
            "Content after an unclosed $$ must still parse"
        )
    }

    func testMathFenceAcceptsTrailingParameters() {
        let blocks = parseMarkdownBlocks(
            from: "```math display\nx^2\n```"
        )

        guard case .math(_, let formula) = blocks.first else {
            XCTFail("```math display must parse as math, like plan/chart fences")
            return
        }
        XCTAssertTrue(formula.contains("x^2"))
    }

    func testSolutionFenceParsesAsSolutionDocument() {
        let blocks = parseMarkdownBlocks(
            from: "**Correct Answer: C**\n\n```solution\nStep 1: reason\n```"
        )

        XCTAssertEqual(blocks.count, 2)
        guard case .solution(_, let content) = blocks.last else {
            XCTFail("```solution must parse as a solution document, like ```plan")
            return
        }
        XCTAssertTrue(content.contains("Step 1"))
    }

    func testSolutionFenceAcceptsTrailingParametersAndCase() {
        XCTAssertTrue(isSolutionFenceLanguage("solution"))
        XCTAssertTrue(isSolutionFenceLanguage("Solution full"))
        XCTAssertFalse(isSolutionFenceLanguage("plan"))
        XCTAssertFalse(isSolutionFenceLanguage("swift"))
    }

    func testSolutionFenceStaysCodeWhenDocumentsDisabled() {
        let blocks = parseMarkdownBlocks(
            from: "```solution\nStep 1\n```",
            allowsPlanDocuments: false
        )

        guard case .code(_, let language, _) = blocks.first else {
            XCTFail("A solution fence must stay a code block when documents are disabled")
            return
        }
        XCTAssertEqual(language, "solution")
    }

    private func numberedItem(from block: MarkdownBlock) -> String? {
        guard case .numberedItem(_, let number, _) = block else {
            return nil
        }

        return number
    }
}

import AppKit
import XCTest
@testable import AgenticSidebar

/// The run is what makes a whole answer selectable in one drag, so these tests
/// pin down what belongs in it and what the text it produces looks like.
final class MarkdownTextRunBuilderTests: XCTestCase {
    private let typography = MarkdownRunTypography(
        fontFamily: .system,
        pointSize: 14,
        lineSpacing: 4
    )

    func testOnlyProseBlocksShareOneTextView() {
        let source = """
        Prose.

        ```swift
        let value = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---

        ```plan
        - step
        ```
        """

        let blocks = parseMarkdownBlocks(from: source)

        let textual = blocks.filter(MarkdownTextRunBuilder.isTextual)
        XCTAssertTrue(
            textual.allSatisfy {
                if case .paragraph = $0 { return true }
                return false
            },
            "A code block, table, divider or plan ends the run instead of joining it"
        )
        XCTAssertFalse(
            textual.contains { block in
                if case .table = block { return true }
                return false
            }
        )
    }

    func testHeadingsListsAndQuotesStayInTheRun() throws {
        let blocks = parseMarkdownBlocks(
            from: "# Heading\n\n- item\n\n1. one\n\n> quoted\n\nA paragraph."
        )

        XCTAssertEqual(
            blocks.filter(MarkdownTextRunBuilder.isTextual).count,
            blocks.count,
            "Every block here is prose, so none of it should split the selection"
        )

        let text = MarkdownTextRunBuilder.attributedString(
            blocks: blocks,
            typography: typography
        ).string

        for fragment in ["Heading", "item", "one", "quoted", "A paragraph."] {
            XCTAssertTrue(text.contains(fragment), "Missing \(fragment) in \(text)")
        }
        XCTAssertTrue(text.contains("•"), "A bullet is drawn as part of the run")
    }

    func testInlineEmphasisSurvivesTheConversionToAppKitAttributes() throws {
        let blocks = parseMarkdownBlocks(from: "Plain **bold** and `code`.")

        let run = MarkdownTextRunBuilder.attributedString(
            blocks: blocks,
            typography: typography
        )
        let text = run.string as NSString

        let boldFont = try XCTUnwrap(
            run.attribute(.font, at: text.range(of: "bold").location, effectiveRange: nil)
                as? NSFont
        )
        XCTAssertTrue(
            NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask),
            "AppKit ignores InlinePresentationIntent, so the emphasis has to become a font"
        )

        let codeFont = try XCTUnwrap(
            run.attribute(.font, at: text.range(of: "code").location, effectiveRange: nil)
                as? NSFont
        )
        XCTAssertTrue(codeFont.isFixedPitch)

        let plainFont = try XCTUnwrap(
            run.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertFalse(NSFontManager.shared.traits(of: plainFont).contains(.boldFontMask))
    }

    func testTheLastParagraphLeavesTheGapToTheNextViewToItsNeighbour() throws {
        let blocks = parseMarkdownBlocks(from: "First.\n\nSecond.")
        let run = MarkdownTextRunBuilder.attributedString(
            blocks: blocks,
            typography: typography
        )
        let text = run.string as NSString

        let firstStyle = try XCTUnwrap(
            run.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(firstStyle.paragraphSpacing, 10)

        // The run is a view in a stack that already spaces its children, so a
        // trailing gap inside the text would double the gap after a code block.
        let lastIndex = text.range(of: "Second.").location
        let lastStyle = try XCTUnwrap(
            run.attribute(.paragraphStyle, at: lastIndex, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(lastStyle.paragraphSpacing, 0)
    }

    /// The height this reports is the height SwiftUI gives the run, so a run that
    /// measures short is a clipped answer — the failure mode that a rendering
    /// change like this one has to rule out without a screen.
    @MainActor
    func testARunMeasuresToTheHeightItsTextNeeds() {
        let textView = SelectableMarkdownTextView.makeTextView()
        textView.textStorage?.setAttributedString(
            MarkdownTextRunBuilder.attributedString(
                blocks: parseMarkdownBlocks(from: "One short line."),
                typography: typography
            )
        )

        let short = SelectableMarkdownTextView.measuredSize(of: textView, width: 400)
        XCTAssertEqual(short.width, 400)
        XCTAssertGreaterThan(short.height, 0, "A zero height is invisible text")

        let paragraph = String(
            repeating: "A sentence that has to wrap at four hundred points. ",
            count: 20
        )
        textView.textStorage?.setAttributedString(
            MarkdownTextRunBuilder.attributedString(
                blocks: parseMarkdownBlocks(from: paragraph),
                typography: typography
            )
        )

        let long = SelectableMarkdownTextView.measuredSize(of: textView, width: 400)
        XCTAssertGreaterThan(
            long.height,
            short.height,
            "A longer run has to report more height"
        )

        let narrower = SelectableMarkdownTextView.measuredSize(of: textView, width: 200)
        XCTAssertGreaterThan(
            narrower.height,
            long.height,
            "The same text at half the width needs more lines"
        )
    }

    func testTheTokenFollowsBothTheContentAndTheTypography() {
        let blocks = parseMarkdownBlocks(from: "First.")

        let token = MarkdownTextRunBuilder.token(blocks: blocks, typography: typography)
        XCTAssertEqual(
            token,
            MarkdownTextRunBuilder.token(blocks: blocks, typography: typography),
            "An unchanged run must not be rebuilt and re-laid out"
        )

        XCTAssertNotEqual(
            token,
            MarkdownTextRunBuilder.token(
                blocks: parseMarkdownBlocks(from: "First. And more."),
                typography: typography
            )
        )

        XCTAssertNotEqual(
            token,
            MarkdownTextRunBuilder.token(
                blocks: blocks,
                typography: MarkdownRunTypography(
                    fontFamily: .serif,
                    pointSize: 14,
                    lineSpacing: 4
                )
            )
        )
    }
}

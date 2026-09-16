import XCTest
@testable import AgenticSidebar

final class PromptNavigatorRailTests: XCTestCase {
    func testASinglePromptSitsAtTheMiddleOfTheColumn() {
        let layout = PromptRailMetrics.layout(at: 0, of: 1)
        let middle = PromptRailMetrics.layout(at: 1, of: 3)

        XCTAssertEqual(layout, middle, "One prompt has nowhere else to sit but the middle")
    }

    func testBarsGrowAndDriftRightTowardTheMiddle() {
        let count = 9
        let layouts = (0..<count).map { PromptRailMetrics.layout(at: $0, of: count) }
        let middle = count / 2

        for index in 0..<middle {
            let closer = layouts[index + 1]
            let further = layouts[index]

            XCTAssertGreaterThan(
                closer.width,
                further.width,
                "The column reads as a spindle: bar \\(index + 1) must be longer than bar \\(index)"
            )
            XCTAssertGreaterThan(closer.leadingOffset, further.leadingOffset)
            XCTAssertGreaterThan(closer.opacity, further.opacity)
        }

        XCTAssertEqual(layouts[middle], layouts[count - 1 - middle], "The column is symmetric")
    }

    func testEveryBarStaysInsideTheColumnItIsGiven() {
        for count in [2, 5, 12, PromptRailMetrics.maximumBarCount] {
            for index in 0..<count {
                let layout = PromptRailMetrics.layout(at: index, of: count)
                let railPadding: CGFloat = 6
                let activeBump: CGFloat = 4
                let rightEdge = railPadding + layout.leadingOffset + layout.width + activeBump

                XCTAssertLessThanOrEqual(
                    rightEdge,
                    PromptRailMetrics.columnWidth,
                    "A bar may not spill into the transcript (\\(count) prompts, bar \\(index))"
                )
            }
        }
    }

    func testThePromptBeingReadIsTheLowestOneAboveTheTopOfTheViewport() {
        let ids = (0..<5).map { _ in UUID() }
        let offsets: [UUID: CGFloat] = [
            ids[0]: -400,
            ids[1]: -120,
            ids[2]: 6,
            ids[3]: 180,
            ids[4]: 900
        ]

        XCTAssertEqual(
            PromptRailSelection.activeID(among: ids, offsets: offsets),
            ids[2],
            "The prompt whose first line is at the top of the view is the one being read"
        )
    }

    func testUnmeasuredAndOffscreenPromptsDoNotStealTheHighlight() {
        let ids = (0..<4).map { _ in UUID() }

        XCTAssertEqual(
            PromptRailSelection.activeID(
                among: ids,
                offsets: [ids[0]: -900, ids[1]: -520]
            ),
            ids[1],
            "Scrolling above the conversation keeps the last prompt above the fold lit"
        )

        XCTAssertEqual(
            PromptRailSelection.activeID(
                among: ids,
                offsets: [ids[0]: -900, ids[1]: 640]
            ),
            ids[0],
            "A prompt further down has not been reached yet"
        )

        XCTAssertNil(
            PromptRailSelection.activeID(among: ids, offsets: [:]),
            "Nothing is lit until a row has been measured"
        )
    }
}

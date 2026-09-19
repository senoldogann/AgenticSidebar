import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class ComposerDraftCenterTests: XCTestCase {
    func testARestoreIsHandedOverExactlyOnce() {
        let center = ComposerDraftCenter()
        let sessionID = UUID()

        center.requestRestore(text: "do that again", attachmentPaths: [], sessionID: sessionID)

        let request = center.consumePending(for: sessionID)
        XCTAssertEqual(request?.text, "do that again")
        XCTAssertEqual(request?.sessionID, sessionID)
        XCTAssertNil(
            center.pending,
            "A request that stayed pending would re-apply on the next redraw"
        )
        XCTAssertNil(center.consumePending(for: sessionID))
    }

    func testEachRestoreCarriesItsOwnIdentity() {
        let center = ComposerDraftCenter()
        let sessionID = UUID()

        let first = center.requestRestore(text: "same text", attachmentPaths: [], sessionID: sessionID)
        let second = center.requestRestore(text: "same text", attachmentPaths: [], sessionID: sessionID)

        XCTAssertNotEqual(
            first.id,
            second.id,
            "Clicking the same message twice has to be two events, or the second does nothing"
        )
    }

    func testConsumePendingForMatchingSessionConsumesRequest() {
        let center = ComposerDraftCenter()
        let targetSessionID = UUID()
        let otherSessionID = UUID()

        center.requestRestore(text: "draft for target", attachmentPaths: [], sessionID: targetSessionID)

        let otherAttempt = center.consumePending(for: otherSessionID)
        XCTAssertNil(
            otherAttempt,
            "A different pane must not consume a restore meant for another session"
        )
        XCTAssertNotNil(
            center.pending,
            "Pending request must remain until the matching session consumes it"
        )

        let targetAttempt = center.consumePending(for: targetSessionID)
        XCTAssertEqual(targetAttempt?.text, "draft for target")
        XCTAssertNil(
            center.pending,
            "Matching session should have consumed and cleared the pending request"
        )
    }

    func testARestoreNamesTheSessionItBelongsTo() {
        let center = ComposerDraftCenter()
        let sessionID = UUID()

        let request = center.requestRestore(
            text: "with a file",
            attachmentPaths: ["/tmp/report.pdf"],
            sessionID: sessionID
        )

        XCTAssertEqual(request.sessionID, sessionID)
        XCTAssertEqual(request.attachmentPaths, ["/tmp/report.pdf"])
    }
}

final class ComposerDraftPlacementTests: XCTestCase {
    func testAnEmptyFieldTakesTheRestoredMessageAsItIs() {
        XCTAssertEqual(
            ComposerDraftPlacement.merged(existing: "   ", restored: "  second attempt  "),
            "second attempt"
        )
    }

    func testADraftInProgressIsKeptAndTheRestoredMessageFollowsIt() {
        XCTAssertEqual(
            ComposerDraftPlacement.merged(
                existing: "half-written thought",
                restored: "the message to write again"
            ),
            "half-written thought\n\nthe message to write again",
            "Replacing a draft would destroy work the user never agreed to lose"
        )
    }

    func testAnEmptyRestoreChangesNothing() {
        XCTAssertEqual(
            ComposerDraftPlacement.merged(existing: "kept", restored: "   "),
            "kept"
        )
    }
}

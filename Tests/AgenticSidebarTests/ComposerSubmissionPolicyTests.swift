import XCTest

@testable import AgenticSidebar

final class ComposerSubmissionPolicyTests: XCTestCase {
    func testPlainReturnSubmitsOnlyWhenSubmissionIsAvailable() {
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(
                for: .plain,
                availability: .available
            ),
            .submit
        )
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(
                for: .plain,
                availability: .unavailable
            ),
            .suppress
        )
    }

    func testShiftReturnAlwaysDefersToNativeNewlineBehavior() {
        for availability in [
            ComposerSubmissionAvailability.available,
            .unavailable,
        ] {
            XCTAssertEqual(
                ComposerSubmissionPolicy.action(
                    for: .shifted,
                    availability: availability
                ),
                .insertNewline
            )
        }
    }

    func testOtherModifierCombinationsNeverSubmit() {
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(
                for: .modified,
                availability: .available
            ),
            .systemDefault
        )
    }
}

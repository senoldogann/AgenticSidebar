import Foundation
import XCTest

@testable import AgenticSidebar

/// Kapı matrisi: dördü birden yeşil olmadan `done` çıkmaz.
final class GoalVerifierTests: XCTestCase {
    func testAllGreenIsDone() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: true,
                testsSucceeded: true,
                criticalOrHighFindings: 0,
                unmetCriteria: 0
            ))
        XCTAssertEqual(decision, .done)
    }

    func testFailedBuildNeedsFixing() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: false,
                testsSucceeded: true,
                criticalOrHighFindings: 0,
                unmetCriteria: 0
            ))
        XCTAssertEqual(decision, .fixing(reasons: ["build failed"]))
    }

    func testFailedTestsNeedFixing() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: true,
                testsSucceeded: false,
                criticalOrHighFindings: 0,
                unmetCriteria: 0
            ))
        XCTAssertEqual(decision, .fixing(reasons: ["tests failed"]))
    }

    func testReviewFindingsNeedFixingWithCount() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: true,
                testsSucceeded: true,
                criticalOrHighFindings: 2,
                unmetCriteria: 0
            ))
        XCTAssertEqual(decision, .fixing(reasons: ["2 critical/high review findings open"]))
    }

    func testUnmetCriteriaNeedFixingWithCount() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: true,
                testsSucceeded: true,
                criticalOrHighFindings: 0,
                unmetCriteria: 3
            ))
        XCTAssertEqual(decision, .fixing(reasons: ["3 acceptance criteria unmet"]))
    }

    func testMultipleRedGatesListEveryReason() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: false,
                testsSucceeded: false,
                criticalOrHighFindings: 1,
                unmetCriteria: 1
            ))
        guard case .fixing(let reasons) = decision else {
            XCTFail("Kırmızı kapılar varken karar done olamaz")
            return
        }
        XCTAssertEqual(reasons.count, 4)
    }

    func testCriticalFindingAloneBlocksDone() {
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: true,
                testsSucceeded: true,
                criticalOrHighFindings: 1,
                unmetCriteria: 0
            ))
        XCTAssertNotEqual(decision, .done)
    }
}

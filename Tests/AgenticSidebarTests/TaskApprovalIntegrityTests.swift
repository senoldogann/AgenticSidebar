import Foundation
import XCTest

@testable import AgenticSidebar

final class TaskApprovalIntegrityTests: XCTestCase {
    func testAcceptanceRejectsApprovalFromAnotherAttempt() throws {
        let taskID = UUID()
        let currentAttemptID = UUID()
        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Review task",
            objective: "Accept only the reviewed attempt",
            status: .review,
            stage: .acceptance,
            criteria: [],
            currentAttemptID: currentAttemptID
        )
        let approval = TaskApproval(
            taskID: taskID,
            attemptID: UUID(),
            fingerprint: "verified-fingerprint",
            actor: "reviewer",
            action: .accept
        )
        let context = TaskTransitionContext(
            fingerprint: "verified-fingerprint",
            actor: "reviewer",
            evidenceIDs: [UUID()],
            humanApproval: approval
        )

        XCTAssertThrowsError(try TaskStateMachine.transition(task, action: .accept, context: context)) { error in
            XCTAssertEqual(error as? TaskTransitionError, .missingHumanAcceptance)
        }
    }
}

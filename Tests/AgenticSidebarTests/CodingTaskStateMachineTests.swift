import Foundation
import XCTest

@testable import AgenticSidebar

final class CodingTaskStateMachineTests: XCTestCase {

    func testCannotCompleteWithoutAcceptance() throws {
        let projectID = UUID()
        let taskID = UUID()
        let criterionID = UUID()
        let criterion = CodingAcceptanceCriterion(
            id: criterionID,
            taskID: taskID,
            description: "Build must pass",
            isCompleted: true,
            evidenceID: UUID()
        )

        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: "Test Task",
            objective: "Implement feature safely",
            priority: 1,
            status: .review,
            stage: .acceptance,
            version: 3,
            criteria: [criterion]
        )

        let contextWithoutAcceptance = TaskTransitionContext(
            fingerprint: "abc12345",
            actor: "developer",
            evidenceIDs: [UUID()],
            humanApproval: nil
        )

        XCTAssertThrowsError(
            try TaskStateMachine.transition(task, action: .accept, context: contextWithoutAcceptance)
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(transitionError, .missingHumanAcceptance)
        }
    }

    func testCancelledAttemptCannotBecomeDone() throws {
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Cancelled Task",
            objective: "Do something",
            priority: 2,
            status: .cancelled,
            stage: .plan,
            version: 4,
            criteria: []
        )

        let context = TaskTransitionContext(
            fingerprint: "abc12345",
            actor: "user",
            evidenceIDs: [],
            humanApproval: TaskApproval(
                id: UUID(),
                taskID: task.id,
                attemptID: UUID(),
                fingerprint: "abc12345",
                actor: "user",
                timestamp: Date(),
                action: .accept
            )
        )

        XCTAssertThrowsError(
            try TaskStateMachine.transition(task, action: .accept, context: context)
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(transitionError, .taskTerminal(status: .cancelled))
        }
    }

    func testVersionAdvancesOnLegalTransition() throws {
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Backlog Task",
            objective: "Set up scaffolding",
            priority: 1,
            status: .backlog,
            stage: .analysis,
            version: 1,
            criteria: []
        )

        let context = TaskTransitionContext(
            fingerprint: "initial",
            actor: "system",
            evidenceIDs: [],
            humanApproval: nil
        )

        let updatedTask = try TaskStateMachine.transition(task, action: .markReady, context: context)

        XCTAssertEqual(updatedTask.status, .ready)
        XCTAssertEqual(updatedTask.version, 2)
        XCTAssertEqual(task.version, 1, "Original task value should remain immutable")
    }

    func testCannotCompleteWithUnmetCriteria() throws {
        let taskID = UUID()
        let criterion1 = CodingAcceptanceCriterion(
            taskID: taskID,
            description: "Step 1",
            isCompleted: true,
            evidenceID: UUID()
        )
        let criterion2 = CodingAcceptanceCriterion(
            taskID: taskID,
            description: "Step 2",
            isCompleted: false,
            evidenceID: nil
        )

        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Multi-criteria Task",
            objective: "Complete both steps",
            priority: 1,
            status: .review,
            stage: .acceptance,
            version: 2,
            criteria: [criterion1, criterion2]
        )

        let context = TaskTransitionContext(
            fingerprint: "hash999",
            actor: "reviewer",
            evidenceIDs: [UUID()],
            humanApproval: TaskApproval(
                id: UUID(),
                taskID: taskID,
                attemptID: UUID(),
                fingerprint: "hash999",
                actor: "user",
                timestamp: Date(),
                action: .accept
            )
        )

        XCTAssertThrowsError(
            try TaskStateMachine.transition(task, action: .accept, context: context)
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(transitionError, .unmetCriteria([criterion2.id]))
        }
    }

    func testCannotCompleteWithChangedFingerprint() throws {
        let taskID = UUID()
        let attemptID = UUID()
        let criterion = CodingAcceptanceCriterion(
            taskID: taskID,
            description: "Passing tests",
            isCompleted: true,
            evidenceID: UUID()
        )

        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Task with stale fingerprint",
            objective: "Verify fingerprint matching",
            priority: 1,
            status: .review,
            stage: .acceptance,
            version: 3,
            criteria: [criterion],
            currentAttemptID: attemptID
        )

        let context = TaskTransitionContext(
            fingerprint: "newFingerprintHash",
            actor: "user",
            evidenceIDs: [UUID()],
            humanApproval: TaskApproval(
                id: UUID(),
                taskID: taskID,
                attemptID: attemptID,
                fingerprint: "oldFingerprintHash",
                actor: "user",
                timestamp: Date(),
                action: .accept
            )
        )

        XCTAssertThrowsError(
            try TaskStateMachine.transition(task, action: .accept, context: context)
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(
                transitionError,
                .fingerprintMismatch(expected: "newFingerprintHash", actual: "oldFingerprintHash")
            )
        }
    }

    func testCannotDirectlyTransitionFromReadyToDone() throws {
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Ready Task",
            objective: "Try skipping steps",
            priority: 1,
            status: .ready,
            stage: .plan,
            version: 2,
            criteria: []
        )

        let context = TaskTransitionContext(
            fingerprint: "hash",
            actor: "user",
            evidenceIDs: [UUID()],
            humanApproval: TaskApproval(
                id: UUID(),
                taskID: task.id,
                attemptID: UUID(),
                fingerprint: "hash",
                actor: "user",
                timestamp: Date(),
                action: .accept
            )
        )

        XCTAssertThrowsError(
            try TaskStateMachine.transition(task, action: .accept, context: context)
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            switch transitionError {
            case .illegalTransition(let from, let to, _):
                XCTAssertEqual(from, .ready)
                XCTAssertEqual(to, .done)
            default:
                XCTFail("Expected illegalTransition, got \(transitionError)")
            }
        }
    }

    func testDoneCannotTransitionToRunning() throws {
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Completed Task",
            objective: "Done objective",
            priority: 1,
            status: .done,
            stage: .acceptance,
            version: 5,
            criteria: []
        )

        let context = TaskTransitionContext(fingerprint: "hash", actor: "agent")

        XCTAssertThrowsError(
            try TaskStateMachine.transition(
                task,
                action: .startAttempt(attemptID: UUID(), role: .developer),
                context: context
            )
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(transitionError, .taskTerminal(status: .done))
        }
    }

    func testBlockAndUnblockPreservesStage() throws {
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Running Task",
            objective: "Work on feature",
            priority: 1,
            status: .running,
            stage: .implementation,
            version: 2,
            criteria: []
        )

        let context = TaskTransitionContext(fingerprint: "hash", actor: "system")

        let blockedTask = try TaskStateMachine.transition(
            task,
            action: .block(reason: .rateLimited),
            context: context
        )

        XCTAssertEqual(blockedTask.status, .blocked)
        XCTAssertEqual(blockedTask.previousStageBeforeBlock, .implementation)
        XCTAssertEqual(blockedTask.blockReason, .rateLimited)
        XCTAssertEqual(blockedTask.version, 3)

        let unblockedTask = try TaskStateMachine.transition(
            blockedTask,
            action: .unblock,
            context: context
        )

        XCTAssertEqual(unblockedTask.status, .ready)
        XCTAssertEqual(unblockedTask.stage, .implementation)
        XCTAssertNil(unblockedTask.blockReason)
        XCTAssertNil(unblockedTask.previousStageBeforeBlock)
        XCTAssertEqual(unblockedTask.version, 4)
    }

    func testSubmitForReviewRequiresEvidence() throws {
        let task = CodingTask(
            id: UUID(),
            projectID: UUID(),
            title: "Running Task",
            objective: "Needs verification",
            priority: 1,
            status: .running,
            stage: .implementation,
            version: 2,
            criteria: []
        )

        let contextWithoutEvidence = TaskTransitionContext(
            fingerprint: "hash",
            actor: "agent",
            evidenceIDs: []
        )

        XCTAssertThrowsError(
            try TaskStateMachine.transition(task, action: .submitForReview, context: contextWithoutEvidence)
        ) { error in
            guard let transitionError = error as? TaskTransitionError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(transitionError, .missingVerificationEvidence)
        }

        let contextWithEvidence = TaskTransitionContext(
            fingerprint: "hash",
            actor: "agent",
            evidenceIDs: [UUID()]
        )

        let reviewTask = try TaskStateMachine.transition(
            task,
            action: .submitForReview,
            context: contextWithEvidence
        )

        XCTAssertEqual(reviewTask.status, .review)
        XCTAssertEqual(reviewTask.stage, .acceptance)
        XCTAssertEqual(reviewTask.version, 3)
    }
}

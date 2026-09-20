import Foundation
import XCTest

@testable import AgenticSidebar

final class AcceptanceGateTests: XCTestCase {
    private let currentFingerprint = "fingerprint-current"
    private let otherFingerprint = "fingerprint-other"

    // MARK: - Complete fixtures

    func testCompletePassingFixtureIsReadyForHumanReviewWithoutApproval() {
        let fixture = completeFixture()

        let decision = evaluate(fixture)

        XCTAssertEqual(decision, .readyForHumanReview)
        XCTAssertNotEqual(decision, .accepted)
    }

    func testCompletePassingFixtureIsAcceptedWithMatchingApproval() {
        let fixture = completeFixture()

        let decision = evaluate(fixture, approvals: [acceptApproval(for: fixture)])

        XCTAssertEqual(decision, .accepted)
    }

    func testMergeApprovalDoesNotAuthorizeCompletion() {
        let fixture = completeFixture()
        let mergeApproval = TaskApproval(
            taskID: fixture.task.id,
            attemptID: fixture.attempt.id,
            fingerprint: currentFingerprint,
            actor: "reviewer",
            action: .merge
        )

        let decision = evaluate(fixture, approvals: [mergeApproval])

        XCTAssertEqual(decision, .readyForHumanReview)
    }

    // MARK: - RED matrix: every listed failure denies done

    func testFailedBuildDeniesDone() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(taskID: fixture.task.id, attemptID: fixture.attempt.id, statuses: ["build": .failed])

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .requiredStepNotPassed(name: "build", status: .failed))
    }

    func testFailedTestsDenyDone() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(taskID: fixture.task.id, attemptID: fixture.attempt.id, statuses: ["test": .failed])

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .requiredStepNotPassed(name: "test", status: .failed))
    }

    func testStaleFingerprintDeniesDone() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(
            taskID: fixture.task.id,
            attemptID: fixture.attempt.id,
            fingerprint: otherFingerprint
        )

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(
            decision,
            contains: .requiredStepFingerprintMismatch(name: "build", recorded: otherFingerprint, current: currentFingerprint)
        )
    }

    func testAbsentRequiredLintDeniesDone() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(taskID: fixture.task.id, attemptID: fixture.attempt.id, omitting: ["format"])

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .missingRequiredStep(name: "format"))
    }

    func testSkippedRequiredLintDeniesDone() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(taskID: fixture.task.id, attemptID: fixture.attempt.id, statuses: ["format": .skipped])

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .requiredStepNotPassed(name: "format", status: .skipped))
    }

    func testOpenHighFindingDeniesDone() {
        let fixture = completeFixture()
        let finding = makeFinding(for: fixture, severity: .high)

        let decision = evaluate(fixture, findings: [finding])

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .openBlockingFindings(ids: [finding.id]))
    }

    func testUnsetCriterionDeniesDone() {
        let fixture = completeFixture(criterionCompleted: false)

        let decision = evaluate(fixture)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .unmetCriteria(ids: [fixture.criterion.id]))
    }

    func testMissingUserAcceptanceIsNotAccepted() {
        let fixture = completeFixture()

        let decision = evaluate(fixture)

        XCTAssertEqual(decision, .readyForHumanReview)
        assertDeniesDone(decision)
    }

    func testWrongAttemptApprovalDeniesDone() {
        let fixture = completeFixture()
        let otherAttemptID = UUID()
        let approval = TaskApproval(
            taskID: fixture.task.id,
            attemptID: otherAttemptID,
            fingerprint: currentFingerprint,
            actor: "reviewer",
            action: .accept
        )

        let decision = evaluate(fixture, approvals: [approval])

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .acceptanceApprovalAttemptMismatch(expected: fixture.attempt.id, actual: otherAttemptID))
    }

    func testChangedFileAfterApprovalDeniesDone() {
        let fixture = completeFixture()
        let approval = TaskApproval(
            taskID: fixture.task.id,
            attemptID: fixture.attempt.id,
            fingerprint: otherFingerprint,
            actor: "reviewer",
            action: .accept
        )

        let decision = evaluate(fixture, approvals: [approval])

        assertDeniesDone(decision)
        assertBlocked(
            decision,
            contains: .acceptanceApprovalFingerprintMismatch(expected: currentFingerprint, actual: otherFingerprint)
        )
    }

    // MARK: - Fabricated or stale evidence never closes a task

    func testModelSuccessTextIsNotEvidence() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(
            taskID: fixture.task.id,
            attemptID: fixture.attempt.id,
            statuses: ["build": .failed],
            details: "all tests passed"
        )

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .requiredStepNotPassed(name: "build", status: .failed))
    }

    func testLegacyEvidenceWithoutRecipeVersionCannotSatisfyRequiredStep() {
        let fixture = completeFixture()
        let evidence = requiredEvidence(taskID: fixture.task.id, attemptID: fixture.attempt.id, recipeVersion: nil)

        let decision = evaluate(fixture, evidence: evidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .requiredStepUnknownRecipeVersion(name: "build", version: nil))
    }

    func testEvidenceFromAnotherTaskCannotSatisfyRequiredStep() {
        let fixture = completeFixture()
        let foreignEvidence = requiredEvidence(taskID: UUID(), attemptID: fixture.attempt.id)

        let decision = evaluate(fixture, evidence: foreignEvidence)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .missingRequiredStep(name: "build"))
    }

    func testUnavailableCurrentFingerprintDeniesDone() {
        let fixture = completeFixture()

        let decision = evaluate(fixture, currentFingerprint: "   ")

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .currentFingerprintUnavailable)
    }

    func testAttemptNotCurrentDeniesDone() {
        let fixture = completeFixture()
        let otherAttemptID = UUID()
        var task = fixture.task
        task.currentAttemptID = otherAttemptID

        let decision = AcceptanceGate.evaluate(
            task: task,
            attempt: fixture.attempt,
            evidence: fixture.evidence,
            findings: [],
            approvals: [acceptApproval(for: fixture)],
            currentFingerprint: currentFingerprint
        )

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .attemptNotCurrent(expected: fixture.attempt.id, actual: otherAttemptID))
    }

    func testTaskNotInReviewDeniesDone() {
        let fixture = completeFixture(status: .running)

        let decision = evaluate(fixture)

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .taskNotInReview(status: .running))
    }

    // MARK: - Finding dismissal

    func testDismissedHighFindingWithHumanRecordDoesNotBlock() {
        let fixture = completeFixture()
        let finding = makeFinding(
            for: fixture,
            severity: .high,
            status: .dismissed,
            dismissalActor: "reviewer",
            dismissalReason: "False positive",
            dismissedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let decision = evaluate(fixture, findings: [finding], approvals: [acceptApproval(for: fixture)])

        XCTAssertEqual(decision, .accepted)
    }

    func testDismissedHighFindingWithoutActorIsTreatedAsOpen() {
        let fixture = completeFixture()
        let finding = makeFinding(
            for: fixture,
            severity: .high,
            status: .dismissed,
            dismissalActor: "   ",
            dismissalReason: "Looks fine"
        )

        let decision = evaluate(fixture, findings: [finding])

        assertDeniesDone(decision)
        assertBlocked(decision, contains: .openBlockingFindings(ids: [finding.id]))
    }

    func testOpenMediumFindingDoesNotBlockAcceptance() {
        let fixture = completeFixture()
        let finding = makeFinding(for: fixture, severity: .medium)

        let decision = evaluate(fixture, findings: [finding], approvals: [acceptApproval(for: fixture)])

        XCTAssertEqual(decision, .accepted)
    }

    func testHighFindingFromSupersededAttemptDoesNotBlockCurrentAttempt() {
        let fixture = completeFixture()
        let finding = makeFinding(for: fixture, severity: .high, attemptID: UUID())

        let decision = evaluate(fixture, findings: [finding], approvals: [acceptApproval(for: fixture)])

        XCTAssertEqual(decision, .accepted)
    }

    // MARK: - Done only after matching acceptance

    func testCompletePassingFixtureReachesDoneOnlyAfterMatchingAcceptance() throws {
        let fixture = completeFixture()
        let evidenceIDs = fixture.evidence.map(\.id)

        let withoutApproval = TaskTransitionContext(
            fingerprint: currentFingerprint,
            actor: "reviewer",
            evidenceIDs: evidenceIDs
        )
        XCTAssertEqual(evaluate(fixture), .readyForHumanReview)
        XCTAssertThrowsError(
            try TaskStateMachine.transition(fixture.task, action: .accept, context: withoutApproval)
        ) { error in
            XCTAssertEqual(error as? TaskTransitionError, .missingHumanAcceptance)
        }

        let approval = acceptApproval(for: fixture)
        let withApproval = TaskTransitionContext(
            fingerprint: currentFingerprint,
            actor: "reviewer",
            evidenceIDs: evidenceIDs,
            humanApproval: approval
        )
        XCTAssertEqual(evaluate(fixture, approvals: [approval]), .accepted)
        let done = try TaskStateMachine.transition(fixture.task, action: .accept, context: withApproval)
        XCTAssertEqual(done.status, .done)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let task: CodingTask
        let attempt: TaskAttempt
        let criterion: CodingAcceptanceCriterion
        let evidence: [VerificationEvidence]
    }

    private func completeFixture(
        status: TaskStatus = .review,
        criterionCompleted: Bool = true
    ) -> Fixture {
        let taskID = UUID()
        let attemptID = UUID()
        let criterion = CodingAcceptanceCriterion(
            taskID: taskID,
            description: "Feature works",
            isCompleted: criterionCompleted,
            evidenceID: criterionCompleted ? UUID() : nil
        )
        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Review task",
            objective: "Reach done only through matching acceptance",
            status: status,
            stage: .acceptance,
            criteria: [criterion],
            currentAttemptID: attemptID
        )
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: taskID,
            attemptSequence: 1,
            role: .developer,
            providerID: "test-provider",
            modelID: "test-model",
            outcome: .succeeded
        )
        return Fixture(
            task: task,
            attempt: attempt,
            criterion: criterion,
            evidence: requiredEvidence(taskID: taskID, attemptID: attemptID)
        )
    }

    private func evaluate(
        _ fixture: Fixture,
        evidence: [VerificationEvidence]? = nil,
        findings: [ReviewFinding] = [],
        approvals: [TaskApproval] = [],
        currentFingerprint: String? = nil
    ) -> AcceptanceDecision {
        AcceptanceGate.evaluate(
            task: fixture.task,
            attempt: fixture.attempt,
            evidence: evidence ?? fixture.evidence,
            findings: findings,
            approvals: approvals,
            currentFingerprint: currentFingerprint ?? self.currentFingerprint
        )
    }

    private func requiredEvidence(
        taskID: UUID,
        attemptID: UUID,
        statuses: [String: VerificationEvidenceStatus] = [:],
        fingerprint: String? = nil,
        recipeVersion: Int? = VerificationRecipe.currentVersion,
        omitting: Set<String> = [],
        details: String = ""
    ) -> [VerificationEvidence] {
        AcceptanceGate.requiredStepNames.filter { !omitting.contains($0) }.enumerated().map { index, name in
            stepEvidence(
                name,
                taskID: taskID,
                attemptID: attemptID,
                status: statuses[name] ?? .passed,
                fingerprint: fingerprint ?? currentFingerprint,
                recipeVersion: recipeVersion,
                details: details,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
    }

    private func stepEvidence(
        _ name: String,
        taskID: UUID,
        attemptID: UUID,
        status: VerificationEvidenceStatus = .passed,
        fingerprint: String?,
        recipeVersion: Int? = VerificationRecipe.currentVersion,
        details: String = "",
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> VerificationEvidence {
        let exitCode: Int32? = status == .passed ? 0 : (status == .failed ? 1 : nil)
        return VerificationEvidence(
            taskID: taskID,
            attemptID: attemptID,
            recipeName: "swiftpm:AgenticSidebar",
            stepName: name,
            status: status,
            exitCode: exitCode,
            timedOut: false,
            detailsRedacted: details.isEmpty ? "step=\(name) status=\(status.rawValue)" : details,
            workspaceFingerprint: fingerprint,
            recordedAt: recordedAt,
            recipeVersion: recipeVersion
        )
    }

    private func acceptApproval(for fixture: Fixture, fingerprint: String? = nil) -> TaskApproval {
        TaskApproval(
            taskID: fixture.task.id,
            attemptID: fixture.attempt.id,
            fingerprint: fingerprint ?? currentFingerprint,
            actor: "reviewer",
            action: .accept
        )
    }

    private func makeFinding(
        for fixture: Fixture,
        severity: ReviewFindingSeverity,
        attemptID: UUID? = nil,
        status: ReviewFindingStatus = .open,
        dismissalActor: String? = nil,
        dismissalReason: String? = nil,
        dismissedAt: Date? = nil
    ) -> ReviewFinding {
        ReviewFinding(
            taskID: fixture.task.id,
            attemptID: attemptID ?? fixture.attempt.id,
            severity: severity,
            summary: "Finding",
            status: status,
            dismissalActor: dismissalActor,
            dismissalReason: dismissalReason,
            dismissedAt: dismissedAt
        )
    }

    private func assertDeniesDone(
        _ decision: AcceptanceDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch decision {
        case .accepted:
            XCTFail("This case must deny done", file: file, line: line)
        case .blocked(let reasons):
            XCTAssertFalse(reasons.isEmpty, "A blocked decision must carry explicit reasons", file: file, line: line)
        case .readyForHumanReview:
            break
        }
    }

    private func assertBlocked(
        _ decision: AcceptanceDecision,
        contains expected: AcceptanceBlockReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .blocked(let reasons) = decision else {
            XCTFail("Expected blocked with \(expected), got \(decision)", file: file, line: line)
            return
        }
        XCTAssertFalse(reasons.isEmpty, "A blocked decision must carry explicit reasons", file: file, line: line)
        XCTAssertTrue(reasons.contains(expected), "Expected \(expected) in \(reasons)", file: file, line: line)
    }
}

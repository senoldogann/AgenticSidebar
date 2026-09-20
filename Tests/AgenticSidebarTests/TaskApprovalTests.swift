import Foundation
import SQLite3
import XCTest

@testable import AgenticSidebar

final class TaskApprovalTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskApprovalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // MARK: - Approval binding

    func testApprovalBindsExactActionTaskAttemptAndFingerprint() {
        let taskID = UUID()
        let attemptID = UUID()
        let approval = TaskApproval(
            taskID: taskID,
            attemptID: attemptID,
            fingerprint: "fingerprint-a",
            actor: "reviewer",
            action: .accept
        )

        XCTAssertTrue(approval.authorizes(action: .accept, taskID: taskID, attemptID: attemptID, fingerprint: "fingerprint-a"))
        XCTAssertFalse(approval.authorizes(action: .merge, taskID: taskID, attemptID: attemptID, fingerprint: "fingerprint-a"))
        XCTAssertFalse(approval.authorizes(action: .accept, taskID: UUID(), attemptID: attemptID, fingerprint: "fingerprint-a"))
        XCTAssertFalse(approval.authorizes(action: .accept, taskID: taskID, attemptID: UUID(), fingerprint: "fingerprint-a"))
    }

    func testChangedContentRevokesApprovalValidity() {
        let taskID = UUID()
        let attemptID = UUID()
        let approval = TaskApproval(
            taskID: taskID,
            attemptID: attemptID,
            fingerprint: "fingerprint-before-edit",
            actor: "reviewer",
            action: .accept
        )

        XCTAssertTrue(approval.authorizes(action: .accept, taskID: taskID, attemptID: attemptID, fingerprint: "fingerprint-before-edit"))
        XCTAssertFalse(approval.authorizes(action: .accept, taskID: taskID, attemptID: attemptID, fingerprint: "fingerprint-after-edit"))
    }

    // MARK: - Explicit dismissal

    func testDismissalRequiresHumanActor() {
        let finding = ReviewFinding(taskID: UUID(), severity: .high, summary: "Unsafe force unwrap")

        XCTAssertThrowsError(try finding.dismissed(by: "   ", reason: "False positive", at: Date())) { error in
            XCTAssertEqual(error as? ReviewFindingError, .missingDismissalActor(findingID: finding.id))
        }
    }

    func testDismissalRequiresReason() {
        let finding = ReviewFinding(taskID: UUID(), severity: .high, summary: "Unsafe force unwrap")

        XCTAssertThrowsError(try finding.dismissed(by: "reviewer", reason: "\n", at: Date())) { error in
            XCTAssertEqual(error as? ReviewFindingError, .missingDismissalReason(findingID: finding.id))
        }
    }

    func testDismissalRecordsTrimmedActorReasonAndTimestamp() throws {
        let finding = ReviewFinding(taskID: UUID(), severity: .high, summary: "Unsafe force unwrap")
        let dismissedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let dismissed = try finding.dismissed(by: "  reviewer  ", reason: "  False positive  ", at: dismissedAt)

        XCTAssertEqual(dismissed.id, finding.id)
        XCTAssertEqual(dismissed.status, .dismissed)
        XCTAssertEqual(dismissed.dismissalActor, "reviewer")
        XCTAssertEqual(dismissed.dismissalReason, "False positive")
        XCTAssertEqual(dismissed.dismissedAt, dismissedAt)
        XCTAssertTrue(dismissed.isDismissed)
        XCTAssertFalse(dismissed.isOpen)
    }

    func testPersistedDismissalWithoutHumanRecordIsStillOpen() {
        let finding = ReviewFinding(
            taskID: UUID(),
            severity: .high,
            summary: "Unsafe force unwrap",
            status: .dismissed,
            dismissalActor: "reviewer",
            dismissalReason: "   "
        )

        XCTAssertFalse(finding.isDismissed)
        XCTAssertTrue(finding.isOpen)
    }

    // MARK: - Persistence

    func testStoreRoundTripsFindingsAndApprovals() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let attemptID = UUID()

        let finding = ReviewFinding(
            taskID: taskID,
            attemptID: attemptID,
            severity: .high,
            summary: "Unsafe force unwrap",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let approval = TaskApproval(
            taskID: taskID,
            attemptID: attemptID,
            fingerprint: "fingerprint-a",
            actor: "reviewer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            action: .accept
        )
        try await store.recordFinding(finding)
        try await store.recordApproval(approval)

        let findings = try await store.findings(taskID: taskID)
        XCTAssertEqual(findings, [finding])
        let approvals = try await store.approvals(taskID: taskID)
        XCTAssertEqual(approvals, [approval])
        await store.close()
    }

    func testStoreDismissalRecordsHumanActorAndReason() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let finding = ReviewFinding(taskID: taskID, severity: .high, summary: "Unsafe force unwrap")
        try await store.recordFinding(finding)
        let dismissedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let dismissed = try await store.dismissFinding(
            findingID: finding.id,
            actor: "reviewer",
            reason: "False positive",
            at: dismissedAt
        )

        XCTAssertEqual(dismissed.status, .dismissed)
        XCTAssertEqual(dismissed.dismissalActor, "reviewer")
        XCTAssertEqual(dismissed.dismissalReason, "False positive")
        XCTAssertEqual(dismissed.dismissedAt, dismissedAt)
        XCTAssertFalse(dismissed.isOpen)

        let reloaded = try await store.findings(taskID: taskID)
        XCTAssertEqual(reloaded, [dismissed])
        await store.close()
    }

    func testStoreRejectsDismissalWithoutHumanRecord() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let finding = ReviewFinding(taskID: taskID, severity: .high, summary: "Unsafe force unwrap")
        try await store.recordFinding(finding)

        do {
            _ = try await store.dismissFinding(findingID: finding.id, actor: "  ", reason: "False positive", at: Date())
            XCTFail("A dismissal without an actor must be rejected")
        } catch let error as ReviewFindingError {
            XCTAssertEqual(error, .missingDismissalActor(findingID: finding.id))
        }

        let reloaded = try await store.findings(taskID: taskID)
        XCTAssertEqual(reloaded.first?.status, .open)
        await store.close()
    }

    func testStoreRejectsRedismissalOfAlreadyDismissedFinding() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let finding = ReviewFinding(taskID: taskID, severity: .high, summary: "Unsafe force unwrap")
        try await store.recordFinding(finding)
        let firstDismissal = try await store.dismissFinding(
            findingID: finding.id,
            actor: "reviewer",
            reason: "False positive",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        do {
            _ = try await store.dismissFinding(
                findingID: finding.id,
                actor: "other-reviewer",
                reason: "Still fine",
                at: Date(timeIntervalSince1970: 1_700_000_100)
            )
            XCTFail("A second dismissal must not overwrite the recorded one")
        } catch let error as TaskRepositoryError {
            XCTAssertEqual(error, .findingAlreadyDismissed(findingID: finding.id))
        }

        let reloaded = try await store.findings(taskID: taskID)
        XCTAssertEqual(reloaded, [firstDismissal])
        await store.close()
    }

    func testDismissingNonexistentFindingThrowsNotFound() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let missingFindingID = UUID()

        do {
            _ = try await store.dismissFinding(findingID: missingFindingID, actor: "reviewer", reason: "N/A", at: Date())
            XCTFail("Dismissing a finding that does not exist must be rejected")
        } catch let error as TaskRepositoryError {
            XCTAssertEqual(error, .findingNotFound(missingFindingID))
        }
        await store.close()
    }

    func testStoreRejectsApprovalWithoutHumanActor() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let approval = TaskApproval(
            taskID: taskID,
            attemptID: UUID(),
            fingerprint: "fingerprint-a",
            actor: "   ",
            action: .accept
        )

        do {
            try await store.recordApproval(approval)
            XCTFail("An approval without a human actor must be rejected")
        } catch let error as TaskRepositoryError {
            XCTAssertEqual(error, .invalidApprovalActor(approvalID: approval.id))
        }

        let stored = try await store.approvals(taskID: taskID)
        XCTAssertEqual(stored, [])
        await store.close()
    }

    func testStoreRejectsDuplicateApprovalRecord() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let approval = TaskApproval(
            taskID: taskID,
            attemptID: UUID(),
            fingerprint: "fingerprint-a",
            actor: "reviewer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            action: .accept
        )
        try await store.recordApproval(approval)

        do {
            try await store.recordApproval(approval)
            XCTFail("Re-recording the same approval identity must be rejected")
        } catch let error as TaskRepositoryError {
            guard case .duplicateRecord = error else {
                XCTFail("Expected a duplicateRecord error, got \(error)")
                return
            }
        }

        let stored = try await store.approvals(taskID: taskID)
        XCTAssertEqual(stored, [approval])
        await store.close()
    }

    func testStorePersistsInvalidDismissalButConsumersSeeItOpen() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let taskID = UUID()
        try await createTask(in: store, id: taskID)
        let finding = ReviewFinding(
            taskID: taskID,
            severity: .high,
            summary: "Unsafe force unwrap",
            status: .dismissed,
            dismissalActor: "reviewer",
            dismissalReason: "  "
        )
        try await store.recordFinding(finding)

        let reloaded = try await store.findings(taskID: taskID)

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertTrue(reloaded[0].isOpen)
        await store.close()
    }

    func testMigrationToV6AddsReviewTablesAndPreservesExistingRows() async throws {
        let dbURL = tempDirectory.appendingPathComponent("v5-review.sqlite")
        try TaskStoreMigrations.apply(migrations: Array(TaskStoreMigrations.standardMigrations.prefix(5)), to: dbURL)

        let projectID = UUID()
        let taskID = UUID()
        let evidenceID = UUID()
        try withRawDatabase(at: dbURL) { db in
            try TaskStoreMigrations.execute(
                """
                INSERT INTO tasks (
                    id, project_id, title, objective, priority, status, stage,
                    block_reason, previous_stage, version, budget, current_attempt_id,
                    created_at, updated_at
                ) VALUES (
                    '\(taskID.uuidString)', '\(projectID.uuidString)', 'Preserved Task', 'Preserved Objective', 1, 'review', 'acceptance',
                    NULL, NULL, 2, '{}', NULL,
                    1700000000, 1700000000
                );

                INSERT INTO verification_evidence (
                    id, task_id, attempt_id, recipe_name, step_name, status, passed,
                    exit_code, timed_out, details_redacted, workspace_fingerprint, blocked_by, recorded_at, recipe_version
                ) VALUES (
                    '\(evidenceID.uuidString)', '\(taskID.uuidString)', '\(UUID().uuidString)', 'swiftpm:Legacy', 'build', 'passed', 1,
                    0, 0, 'legacy build pass', 'legacy-fingerprint', NULL, 1700000000, 1
                );
                """,
                on: db
            )
        }

        let store = try SQLiteTaskStore.open(at: dbURL)
        XCTAssertEqual(store.currentSchemaVersionSync(), TaskStoreMigrations.standardMigrations.count)

        let task = try await store.task(id: taskID)
        XCTAssertEqual(task?.title, "Preserved Task")
        let evidence = try await store.evidence(id: evidenceID)
        XCTAssertEqual(evidence?.status, .passed)
        XCTAssertEqual(evidence?.stepName, "build")
        let findingsBeforeApproval = try await store.findings(taskID: taskID)
        XCTAssertEqual(findingsBeforeApproval, [])

        let approval = TaskApproval(
            taskID: taskID,
            attemptID: UUID(),
            fingerprint: "fingerprint-a",
            actor: "reviewer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            action: .accept
        )
        try await store.recordApproval(approval)
        let storedApprovals = try await store.approvals(taskID: taskID)
        XCTAssertEqual(storedApprovals, [approval])
        await store.close()
    }

    // MARK: - Atomic acceptance persistence

    func testAcceptTransitionPersistsApprovalAtomicallyWithTaskState() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let seeded = try await seedAcceptableReviewTask(in: store)
        let approval = TaskApproval(
            taskID: seeded.task.id,
            attemptID: seeded.attemptID,
            fingerprint: "verified-fingerprint",
            actor: "reviewer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            action: .accept
        )

        let accepted = try await store.transition(
            taskID: seeded.task.id,
            expectedVersion: seeded.task.version,
            action: .accept,
            context: TaskTransitionContext(
                fingerprint: "verified-fingerprint",
                actor: "reviewer",
                evidenceIDs: [UUID()],
                humanApproval: approval
            )
        )

        XCTAssertEqual(accepted.status, .done)
        let approvals = try await store.approvals(taskID: seeded.task.id)
        XCTAssertEqual(approvals, [approval], "The accept transition must record the actor-correct approval exactly once")
        let reloaded = try await store.task(id: seeded.task.id)
        XCTAssertEqual(reloaded?.status, .done)
        XCTAssertEqual(reloaded?.version, seeded.task.version + 1)
        await store.close()
    }

    func testFailedAcceptTransitionLeavesNoApprovalRow() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let seeded = try await seedAcceptableReviewTask(in: store)
        let approval = TaskApproval(
            taskID: seeded.task.id,
            attemptID: seeded.attemptID,
            fingerprint: "stale-fingerprint",
            actor: "reviewer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            action: .accept
        )

        do {
            _ = try await store.transition(
                taskID: seeded.task.id,
                expectedVersion: seeded.task.version,
                action: .accept,
                context: TaskTransitionContext(
                    fingerprint: "verified-fingerprint",
                    actor: "reviewer",
                    evidenceIDs: [UUID()],
                    humanApproval: approval
                )
            )
            XCTFail("A fingerprint-mismatched approval must not accept the task")
        } catch let error as TaskTransitionError {
            XCTAssertEqual(
                error,
                .fingerprintMismatch(expected: "verified-fingerprint", actual: "stale-fingerprint")
            )
        }

        let approvals = try await store.approvals(taskID: seeded.task.id)
        XCTAssertTrue(approvals.isEmpty, "A rolled-back transition must leave no approval row")
        let reloaded = try await store.task(id: seeded.task.id)
        XCTAssertEqual(reloaded?.status, .review)
        XCTAssertEqual(reloaded?.version, seeded.task.version)
        await store.close()
    }

    func testStaleVersionAcceptTransitionLeavesNoApprovalRow() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let seeded = try await seedAcceptableReviewTask(in: store)
        let approval = TaskApproval(
            taskID: seeded.task.id,
            attemptID: seeded.attemptID,
            fingerprint: "verified-fingerprint",
            actor: "reviewer",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            action: .accept
        )

        do {
            _ = try await store.transition(
                taskID: seeded.task.id,
                expectedVersion: seeded.task.version + 1,
                action: .accept,
                context: TaskTransitionContext(
                    fingerprint: "verified-fingerprint",
                    actor: "reviewer",
                    evidenceIDs: [UUID()],
                    humanApproval: approval
                )
            )
            XCTFail("A stale version must be refused")
        } catch let error as TaskRepositoryError {
            guard case .staleVersion = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }

        let approvals = try await store.approvals(taskID: seeded.task.id)
        XCTAssertTrue(approvals.isEmpty)
        await store.close()
    }

    // MARK: - Helpers

    private func createTask(in store: SQLiteTaskStore, id: UUID) async throws {
        try await store.createTask(
            CodingTask(id: id, projectID: UUID(), title: "Review task", objective: "Reach review acceptance")
        )
    }

    /// Seeds a running task whose single criterion is met and whose attempt is submitted for review.
    private func seedAcceptableReviewTask(in store: SQLiteTaskStore) async throws -> (task: CodingTask, attemptID: UUID) {
        let taskID = UUID()
        let attemptID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Acceptable task",
            objective: "Reach review with completed criteria",
            status: .running,
            stage: .implementation,
            version: 1,
            criteria: [CodingAcceptanceCriterion(taskID: taskID, description: "done", isCompleted: true)],
            currentAttemptID: attemptID,
            createdAt: now,
            updatedAt: now
        )
        try await store.createTask(task)
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: taskID,
            attemptSequence: 1,
            role: .developer,
            providerID: "fixture-runtime",
            modelID: "fixture-model",
            generation: 1,
            startedAt: now
        )
        _ = try await store.claimAttempt(taskID: taskID, expectedVersion: 1, attempt: attempt)
        let submitted = try await store.transition(
            taskID: taskID,
            expectedVersion: 2,
            action: .submitForReview,
            context: TaskTransitionContext(fingerprint: attemptID.uuidString, actor: "agent", evidenceIDs: [UUID()])
        )
        return (submitted, attemptID)
    }

    private func withRawDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let message = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unable to open database"
            if let db { sqlite3_close(db) }
            throw TaskRepositoryError.underlying(message)
        }
        defer { sqlite3_close(db) }
        try body(db)
    }
}

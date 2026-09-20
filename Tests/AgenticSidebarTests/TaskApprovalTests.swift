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

    // MARK: - Helpers

    private func createTask(in store: SQLiteTaskStore, id: UUID) async throws {
        try await store.createTask(
            CodingTask(id: id, projectID: UUID(), title: "Review task", objective: "Reach review acceptance")
        )
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

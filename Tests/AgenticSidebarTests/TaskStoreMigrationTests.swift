import Foundation
import SQLite3
import XCTest

@testable import AgenticSidebar

final class TaskStoreMigrationTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskStoreMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    func testCorruptStorePreservedRatherThanErased() throws {
        let dbURL = tempDirectory.appendingPathComponent("corrupt.sqlite")
        let garbage = "NOT A VALID SQLITE DATABASE FILE HEADER CONTENT".data(using: .utf8)!
        try garbage.write(to: dbURL)

        XCTAssertThrowsError(
            try SQLiteTaskStore.open(at: dbURL)
        ) { error in
            guard let repoError = error as? TaskRepositoryError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            switch repoError {
            case .storeCorrupt:
                break  // Success
            default:
                XCTFail("Unexpected error variant: \(repoError)")
            }
        }

        // File must still exist and must not have been truncated or overwritten
        let reloadedData = try Data(contentsOf: dbURL)
        XCTAssertEqual(reloadedData, garbage, "Corrupt database file must be preserved, never erased or overwritten")
    }

    func testMigrationRollbackOnFailure() throws {
        let dbURL = tempDirectory.appendingPathComponent("rollback.sqlite")

        // 1. Initial valid store
        let store = try SQLiteTaskStore.open(at: dbURL)
        store.closeSync()

        // 2. Attempt applying a failing migration
        let badMigration = TaskStoreMigration(
            version: 999,
            name: "FaultyMigration",
            apply: { db in
                throw TaskRepositoryError.underlying("Forced migration failure")
            }
        )

        XCTAssertThrowsError(
            try TaskStoreMigrations.apply(migrations: [badMigration], to: dbURL)
        )

        // 3. Verify user_version is NOT updated to 999
        let storeAfter = try SQLiteTaskStore.open(at: dbURL)
        let currentVersion = storeAfter.currentSchemaVersionSync()
        storeAfter.closeSync()

        XCTAssertNotEqual(currentVersion, 999, "Failed migration must rollback and not advance schema version")
    }

    func testV1ToLatestMigrationPreservesPopulatedAttemptUsage() async throws {
        let dbURL = tempDirectory.appendingPathComponent("v1-populated.sqlite")
        try TaskStoreMigrations.apply(migrations: Array(TaskStoreMigrations.standardMigrations.prefix(1)), to: dbURL)

        let projectID = UUID()
        let taskID = UUID()
        let attemptID = UUID()
        try withRawDatabase(at: dbURL) { db in
            try TaskStoreMigrations.execute(
                """
                INSERT INTO tasks (
                    id, project_id, title, objective, priority, status, stage,
                    block_reason, previous_stage, version, budget, current_attempt_id,
                    created_at, updated_at
                ) VALUES (
                    '\(taskID.uuidString)', '\(projectID.uuidString)', 'Legacy Task', 'Legacy Objective', 1, 'running', 'implementation',
                    NULL, NULL, 3, '{}', '\(attemptID.uuidString)',
                    1700000000, 1700000000
                );

                INSERT INTO task_attempts (
                    id, task_id, attempt_sequence, role, provider_id, model_id,
                    variant_snapshot, workspace_id, generation, lease_owner,
                    lease_token, lease_expiry, started_at, ended_at, outcome,
                    tool_call_count, duration_seconds
                ) VALUES (
                    '\(attemptID.uuidString)', '\(taskID.uuidString)', 1, 'developer', 'runtime', 'model',
                    NULL, NULL, 1, 'scheduler', 'nonce', 1700001000, 1700000000, NULL, 'inProgress',
                    0, NULL
                );
                """,
                on: db
            )
        }

        let store = try SQLiteTaskStore.open(at: dbURL)
        let version = store.currentSchemaVersionSync()
        XCTAssertEqual(version, TaskStoreMigrations.standardMigrations.count)
        XCTAssertGreaterThanOrEqual(version, 2)

        let reloaded = try await store.task(id: taskID)
        XCTAssertEqual(reloaded?.title, "Legacy Task")
        XCTAssertEqual(reloaded?.version, 3)
        let history = try await store.attemptHistory(taskID: taskID)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.toolCallCount, 0, "A persisted legacy zero must stay zero, never become nil")
        XCTAssertNotNil(history.first?.toolCallCount)
        await store.close()

        try withRawDatabase(at: dbURL) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(repository_leases);", -1, &stmt, nil) == SQLITE_OK else {
                throw TaskRepositoryError.underlying("Unable to inspect repository_leases schema")
            }
            defer { sqlite3_finalize(stmt) }
            var columnNames: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    columnNames.append(String(cString: name))
                }
            }
            XCTAssertTrue(columnNames.contains("attempt_id"), "repository_leases must bind leases to an owning attempt")
        }
    }

    func testV1ToLatestMigrationPreservesPopulatedVerificationEvidence() async throws {
        let dbURL = tempDirectory.appendingPathComponent("v1-evidence.sqlite")
        try TaskStoreMigrations.apply(migrations: Array(TaskStoreMigrations.standardMigrations.prefix(1)), to: dbURL)

        let projectID = UUID()
        let taskID = UUID()
        let passedEvidenceID = UUID()
        let failedEvidenceID = UUID()
        try withRawDatabase(at: dbURL) { db in
            try TaskStoreMigrations.execute(
                """
                INSERT INTO tasks (
                    id, project_id, title, objective, priority, status, stage,
                    block_reason, previous_stage, version, budget, current_attempt_id,
                    created_at, updated_at
                ) VALUES (
                    '\(taskID.uuidString)', '\(projectID.uuidString)', 'Legacy Evidence Task', 'Legacy Evidence', 1, 'running', 'verification',
                    NULL, NULL, 1, '{}', NULL,
                    1700000000, 1700000000
                );

                INSERT INTO verification_evidence (
                    id, task_id, attempt_id, recipe_name, passed, details_redacted, recorded_at
                ) VALUES
                    ('\(passedEvidenceID.uuidString)', '\(taskID.uuidString)', '\(UUID().uuidString)', 'swiftpm:Legacy', 1, 'legacy pass details', 1700000000),
                    ('\(failedEvidenceID.uuidString)', '\(taskID.uuidString)', '\(UUID().uuidString)', 'swiftpm:Legacy', 0, 'legacy fail details', 1700000001);
                """,
                on: db
            )
        }

        let store = try SQLiteTaskStore.open(at: dbURL)
        let version = store.currentSchemaVersionSync()
        XCTAssertEqual(version, TaskStoreMigrations.standardMigrations.count)
        XCTAssertGreaterThanOrEqual(version, 5)

        let passed = try await store.evidence(id: passedEvidenceID)
        XCTAssertEqual(passed?.status, .passed, "a legacy passed=1 row must migrate to status passed")
        XCTAssertEqual(passed?.detailsRedacted, "legacy pass details")
        XCTAssertEqual(passed?.recordedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(passed?.stepName)
        XCTAssertNil(passed?.recipeVersion, "a legacy row may not invent a recipe version")

        let failed = try await store.evidence(id: failedEvidenceID)
        XCTAssertEqual(failed?.status, .failed, "a legacy passed=0 row must migrate to status failed")
        XCTAssertEqual(failed?.detailsRedacted, "legacy fail details")
        XCTAssertEqual(failed?.recordedAt, Date(timeIntervalSince1970: 1_700_000_001))
        await store.close()
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

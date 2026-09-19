import Foundation
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
}

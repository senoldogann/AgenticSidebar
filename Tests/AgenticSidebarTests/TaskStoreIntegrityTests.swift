import Foundation
import SQLite3
import XCTest

@testable import AgenticSidebar

final class TaskStoreIntegrityTests: XCTestCase {
    func testStoreRejectsDependencyCycleWithoutPersistingIt() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let projectID = UUID()
        let first = CodingTask(id: UUID(), projectID: projectID, title: "First", objective: "First task")
        let second = CodingTask(id: UUID(), projectID: projectID, title: "Second", objective: "Second task")
        try await store.createTask(first)
        try await store.createTask(second)

        let forward = TaskDependency(projectID: projectID, prerequisiteTaskID: first.id, dependentTaskID: second.id)
        let backward = TaskDependency(projectID: projectID, prerequisiteTaskID: second.id, dependentTaskID: first.id)
        try await store.addDependency(forward)

        do {
            try await store.addDependency(backward)
            XCTFail("The repository must reject a dependency cycle")
        } catch let error as DependencyGraphError {
            XCTAssertEqual(error, .cyclicDependency(prerequisiteID: second.id, dependentID: first.id))
        }

        let snapshot = try await store.snapshot(projectID: projectID)
        XCTAssertEqual(snapshot.dependencies, [forward], "A rejected dependency must not be persisted")
    }

    // Bozuk satır crash değil storeCorrupt üretmeli.
    func testSnapshotWithCorruptStatusThrowsStoreCorruptInsteadOfCrashing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let task = CodingTask(id: UUID(), projectID: projectID, title: "T", objective: "O")
        let store = try SQLiteTaskStore.open(at: url)
        try await store.createTask(task)
        await store.close()
        try corruptDatabase(at: url, sql: "UPDATE tasks SET status = 'bogus-status' WHERE id = '\(task.id.uuidString)';")
        let reopened = try SQLiteTaskStore.open(at: url)
        defer { reopened.closeSync() }
        do {
            _ = try await reopened.snapshot(projectID: projectID)
            XCTFail("Bozuk status storeCorrupt fırlatmalı")
        } catch let error as TaskRepositoryError {
            guard case .storeCorrupt = error else {
                XCTFail("Beklenen storeCorrupt, gelen \(error)")
                return
            }
        }
    }

    // Geçersiz UUID de crash değil storeCorrupt üretmeli.
    func testSnapshotWithCorruptDependencyThrowsStoreCorruptInsteadOfCrashing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID = UUID()
        let first = CodingTask(id: UUID(), projectID: projectID, title: "A", objective: "A")
        let second = CodingTask(id: UUID(), projectID: projectID, title: "B", objective: "B")
        let store = try SQLiteTaskStore.open(at: url)
        try await store.createTask(first)
        try await store.createTask(second)
        try await store.addDependency(TaskDependency(projectID: projectID, prerequisiteTaskID: first.id, dependentTaskID: second.id))
        await store.close()
        let badSQL =
            "UPDATE task_dependencies SET prerequisite_task_id = 'not-a-uuid' "
            + "WHERE dependent_task_id = '\(second.id.uuidString)';"
        try corruptDatabase(at: url, sql: badSQL)
        let reopened = try SQLiteTaskStore.open(at: url)
        defer { reopened.closeSync() }
        do {
            _ = try await reopened.snapshot(projectID: projectID)
            XCTFail("Bozuk bağımlılık storeCorrupt fırlatmalı")
        } catch let error as TaskRepositoryError {
            guard case .storeCorrupt = error else {
                XCTFail("Beklenen storeCorrupt, gelen \(error)")
                return
            }
        }
    }

    private func corruptDatabase(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw TaskRepositoryError.underlying("Bozuk test verisi yazılamadı")
        }
        defer { sqlite3_close(db) }
        var errMsg: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errMsg) }
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "SQL başarısız"
            throw TaskRepositoryError.underlying(message)
        }
    }
}

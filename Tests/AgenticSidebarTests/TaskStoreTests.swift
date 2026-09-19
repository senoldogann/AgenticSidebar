import Foundation
import XCTest

@testable import AgenticSidebar

final class TaskStoreTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    func testCreateAndReloadPreservesTasksAndCriteria() async throws {
        let dbURL = tempDirectory.appendingPathComponent("tasks.sqlite")
        let projectID = UUID()

        let taskID = UUID()
        let criterion = CodingAcceptanceCriterion(
            id: UUID(),
            taskID: taskID,
            description: "Criterion 1",
            isCompleted: false
        )
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: "Persistent Task",
            objective: "Verify SQLite persistence across restarts",
            criteria: [criterion]
        )

        // 1. Create and write to store
        let store1 = try SQLiteTaskStore.open(at: dbURL)
        try await store1.createTask(task)
        await store1.close()

        // 2. Reopen store and reload
        let store2 = try SQLiteTaskStore.open(at: dbURL)
        let snapshot = try await store2.snapshot(projectID: projectID)
        await store2.close()

        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.id, taskID)
        XCTAssertEqual(snapshot.tasks.first?.title, "Persistent Task")
        XCTAssertEqual(snapshot.tasks.first?.criteria.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.criteria.first?.description, "Criterion 1")
    }

    func testProjectIsolation() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let projectA = UUID()
        let projectB = UUID()

        let taskA = CodingTask(id: UUID(), projectID: projectA, title: "Task A", objective: "Obj A")
        let taskB = CodingTask(id: UUID(), projectID: projectB, title: "Task B", objective: "Obj B")

        try await store.createTask(taskA)
        try await store.createTask(taskB)

        let snapshotA = try await store.snapshot(projectID: projectA)
        let snapshotB = try await store.snapshot(projectID: projectB)

        XCTAssertEqual(snapshotA.tasks.map { $0.id }, [taskA.id])
        XCTAssertEqual(snapshotB.tasks.map { $0.id }, [taskB.id])
    }

    func testStaleVersionRejectsTransition() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let projectID = UUID()
        let task = CodingTask(id: UUID(), projectID: projectID, title: "Task 1", objective: "Obj")
        try await store.createTask(task)

        // Attempt transition with wrong expectedVersion (e.g. 5 instead of 1)
        do {
            _ = try await store.transition(
                taskID: task.id,
                expectedVersion: 5,
                action: .markReady,
                context: TaskTransitionContext(fingerprint: "fp1", actor: "test")
            )
            XCTFail("Expected staleVersion error")
        } catch let error as TaskRepositoryError {
            switch error {
            case .staleVersion(let id, let expected, let actual):
                XCTAssertEqual(id, task.id)
                XCTAssertEqual(expected, 5)
                XCTAssertEqual(actual, 1)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDuplicateActiveAttemptRejected() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let projectID = UUID()
        var task = CodingTask(id: UUID(), projectID: projectID, title: "Task 1", objective: "Obj")
        task.status = .ready
        try await store.createTask(task)

        let attempt1 = TaskAttempt(
            taskID: task.id,
            attemptSequence: 1,
            role: .developer,
            providerID: "claude",
            modelID: "claude-3-7-sonnet",
            workspaceID: UUID(),
            leaseOwner: "runner-1",
            leaseToken: "token-1",
            leaseExpiry: Date().addingTimeInterval(300)
        )

        _ = try await store.claimAttempt(taskID: task.id, expectedVersion: 1, attempt: attempt1)

        // Second attempt claim while first is still active must fail
        let attempt2 = TaskAttempt(
            taskID: task.id,
            attemptSequence: 2,
            role: .developer,
            providerID: "claude",
            modelID: "claude-3-7-sonnet",
            workspaceID: UUID(),
            leaseOwner: "runner-2",
            leaseToken: "token-2",
            leaseExpiry: Date().addingTimeInterval(300)
        )

        do {
            _ = try await store.claimAttempt(taskID: task.id, expectedVersion: 2, attempt: attempt2)
            XCTFail("Expected activeAttemptConflict error")
        } catch let error as TaskRepositoryError {
            switch error {
            case .activeAttemptConflict(let taskID, let existingAttemptID):
                XCTAssertEqual(taskID, task.id)
                XCTAssertEqual(existingAttemptID, attempt1.id)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRepositoryLeaseExclusiveLock() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let repoPath = "/Users/test/repo"
        let task1ID = UUID()
        let task2ID = UUID()

        try await store.acquireRepositoryLease(repositoryPath: repoPath, taskID: task1ID, leaseTimeoutSeconds: 60)

        // Second task attempting to acquire lease on the same repo path must fail
        do {
            try await store.acquireRepositoryLease(repositoryPath: repoPath, taskID: task2ID, leaseTimeoutSeconds: 60)
            XCTFail("Expected repositoryLeaseConflict error")
        } catch let error as TaskRepositoryError {
            switch error {
            case .repositoryLeaseConflict(let path, let heldBy):
                XCTAssertEqual(path, repoPath)
                XCTAssertEqual(heldBy, task1ID)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        // After releasing, task 2 can acquire
        try await store.releaseRepositoryLease(repositoryPath: repoPath, taskID: task1ID)
        try await store.acquireRepositoryLease(repositoryPath: repoPath, taskID: task2ID, leaseTimeoutSeconds: 60)
    }

    func testForeignKeyViolationOnOrphanDependency() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let projectID = UUID()
        let taskA = CodingTask(id: UUID(), projectID: projectID, title: "Task A", objective: "Obj")
        try await store.createTask(taskA)

        // Dependent taskB does NOT exist in store
        let orphanDep = TaskDependency(projectID: projectID, prerequisiteTaskID: taskA.id, dependentTaskID: UUID())

        do {
            try await store.addDependency(orphanDep)
            XCTFail("Expected foreign key violation")
        } catch let error as TaskRepositoryError {
            switch error {
            case .foreignKeyViolation:
                break  // Success
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPersistedAgentProfile() async throws {
        let dbURL = tempDirectory.appendingPathComponent("profiles.sqlite")
        let profile = AgentProfile(
            id: UUID(),
            name: "Senior Coder",
            role: .developer,
            capabilities: ["workspaceWrite", "tools"]
        )

        let store1 = try SQLiteTaskStore.open(at: dbURL)
        try await store1.saveAgentProfile(profile)
        await store1.close()

        let store2 = try SQLiteTaskStore.open(at: dbURL)
        let loaded = try await store2.loadAgentProfile(id: profile.id)
        await store2.close()

        XCTAssertEqual(loaded?.id, profile.id)
        XCTAssertEqual(loaded?.name, "Senior Coder")
        XCTAssertEqual(loaded?.role, .developer)
        XCTAssertEqual(loaded?.capabilities, ["workspaceWrite", "tools"])
    }
}

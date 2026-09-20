import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class TaskBoardStoreTests: XCTestCase {

    private func makeProject(service: CodingTaskService) async throws -> CodingProject {
        try await service.createProject(
            name: "Board",
            repositoryPath: "/tmp/agentic-sidebar-service-tests/repo",
            gitIdentity: "dev@example.com",
            protectedRefs: ["main"]
        )
    }

    @discardableResult
    private func seedTask(
        harness: ServiceTestHarness,
        projectID: UUID,
        title: String,
        priority: Int,
        criteria: [String]
    ) async throws -> CodingTask {
        let taskID = UUID()
        let now = harness.clock.now()
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: title,
            objective: "Objective for \(title)",
            priority: priority,
            status: .backlog,
            stage: .analysis,
            version: 1,
            criteria: criteria.map { CodingAcceptanceCriterion(taskID: taskID, description: $0) },
            createdAt: now,
            updatedAt: now
        )
        try await harness.store.createTask(task)
        return task
    }

    func testRefreshProjectsPersistedCardsAndDetailWithFidelity() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let first = try await seedTask(harness: harness, projectID: project.id, title: "First", priority: 9, criteria: ["c1", "c2"])
        let second = try await seedTask(harness: harness, projectID: project.id, title: "Second", priority: 1, criteria: [])
        try await harness.store.addDependency(
            TaskDependency(projectID: project.id, prerequisiteTaskID: second.id, dependentTaskID: first.id)
        )

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.cards.map(\.title), ["First", "Second"])
        let card = try XCTUnwrap(store.cards.first { $0.id == first.id })
        XCTAssertEqual(card.projectID, project.id)
        XCTAssertEqual(card.objective, "Objective for First")
        XCTAssertEqual(card.priority, 9)
        XCTAssertEqual(card.status, .backlog)
        XCTAssertEqual(card.stage, .analysis)
        XCTAssertEqual(card.version, 1)
        XCTAssertEqual(card.criteriaTotal, 2)
        XCTAssertEqual(card.criteriaCompleted, 0)
        XCTAssertEqual(card.unmetPrerequisiteIDs, [second.id])
        XCTAssertNil(card.activeAttempt)

        await store.selectTask(first.id)
        let detail = try XCTUnwrap(store.detail)
        XCTAssertEqual(detail.card.id, first.id)
        XCTAssertEqual(detail.criteria.map(\.description), ["c1", "c2"])
        XCTAssertEqual(detail.dependencies.map(\.dependentTaskID), [first.id])
        XCTAssertTrue(detail.attempts.isEmpty)
    }

    func testSelectingTasksAndRefreshingNeverExecutesWork() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Idle", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()
        await store.selectTask(task.id)

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.createTask, 0)
        XCTAssertEqual(counts.addDependency, 0)
        XCTAssertEqual(counts.transitions, 0)
        XCTAssertEqual(counts.claimAttempts, 0)
        XCTAssertEqual(counts.endAttempts, 0)
        XCTAssertEqual(counts.recordedEvidence, 0)
        XCTAssertEqual(counts.recordedApprovals, 0)
        XCTAssertFalse(store.isActionInFlight(for: task.id))
        XCTAssertEqual(store.cards.first?.status, .backlog)
    }

    func testStaleStartActionIsRefusedAndBoardResyncs() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Stale", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()
        XCTAssertEqual(store.cards.first?.version, 1)

        _ = try await harness.store.transition(
            taskID: task.id,
            expectedVersion: 1,
            action: .markReady,
            context: TaskTransitionContext(fingerprint: "fixture", actor: "fixture")
        )

        let result = await store.start(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("A stale start must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .stale)

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        let card = try XCTUnwrap(store.cards.first { $0.id == task.id })
        XCTAssertEqual(card.status, .ready)
        XCTAssertEqual(card.version, 2)
        let startAvailability = try XCTUnwrap(store.actionAvailability(for: task.id).first { $0.action == .start })
        XCTAssertTrue(startAvailability.isEnabled)
    }

    func testUnavailableRuntimeRefusalDisablesStartWithMissingCapability() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Unsupported", priority: 1, criteria: [])
        await harness.providers.setResult(.unsupported(missingCapabilities: ["toolUse"]))

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        let result = await store.start(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("An unavailable runtime must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .unavailable)
        XCTAssertTrue(refusal.message.contains("toolUse"))

        let availability = try XCTUnwrap(store.actionAvailability(for: task.id).first { $0.action == .start })
        XCTAssertFalse(availability.isEnabled)
        XCTAssertTrue(availability.disabledReason?.contains("toolUse") == true)

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
        XCTAssertEqual(store.cards.first?.status, .backlog)
    }

    func testAcceptanceRejectionIsNotShownAsOptimisticSuccess() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let seeded = try await harness.seedReviewTask(projectID: project.id, criteriaCompleted: false, evidence: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()
        let before = try XCTUnwrap(store.cards.first { $0.id == seeded.task.id })
        XCTAssertEqual(before.status, .review)

        let result = await store.accept(taskID: seeded.task.id, actor: "reviewer")
        guard case .refused(let refusal) = result else {
            XCTFail("A blocked acceptance must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .blocked)

        let after = try XCTUnwrap(store.cards.first { $0.id == seeded.task.id })
        XCTAssertEqual(after.status, .review)
        XCTAssertEqual(after.version, before.version)
        let approvals = try await harness.store.approvals(taskID: seeded.task.id)
        XCTAssertTrue(approvals.isEmpty)
    }

    func testDuplicateActionForSameTaskIsRefusedWhileInFlight() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Busy", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        let gate = AsyncGate()
        await harness.repository.gateTaskReads(gate)
        let first = Task { await store.start(taskID: task.id) }
        await gate.waitUntilEntered()
        XCTAssertTrue(store.isActionInFlight(for: task.id))

        let second = await store.start(taskID: task.id)
        guard case .refused(let refusal) = second else {
            XCTFail("A duplicate action must be refused, got \(second)")
            return
        }
        XCTAssertEqual(refusal.kind, .busy)

        await gate.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .applied)
        XCTAssertFalse(store.isActionInFlight(for: task.id))
        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 1)
    }

    func testSwitchingSelectionDoesNotCancelInFlightAction() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let running = try await seedTask(harness: harness, projectID: project.id, title: "Running", priority: 2, criteria: [])
        let other = try await seedTask(harness: harness, projectID: project.id, title: "Other", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        let gate = AsyncGate()
        await harness.repository.gateTaskReads(gate)
        let action = Task { await store.start(taskID: running.id) }
        await gate.waitUntilEntered()

        await store.selectTask(other.id)
        await gate.release()
        let result = await action.value
        XCTAssertEqual(result, .applied)

        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedTaskID, other.id)
        XCTAssertEqual(store.detail?.card.id, other.id)
        let card = try XCTUnwrap(store.cards.first { $0.id == running.id })
        XCTAssertEqual(card.status, .running)
        XCTAssertEqual(card.activeAttempt?.generation, 1)
    }

    func testRefreshBurstsAreCoalescedIntoBoundedLoads() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        _ = try await seedTask(harness: harness, projectID: project.id, title: "Task", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()
        let baseline = await harness.repository.mutationCounts().snapshots

        let gate = AsyncGate()
        await harness.repository.gateSnapshots(gate)
        let bursts = (0..<5).map { _ in Task { await store.refresh() } }
        await gate.waitUntilEntered()
        await gate.release()
        for burst in bursts {
            await burst.value
        }

        let after = await harness.repository.mutationCounts().snapshots
        XCTAssertEqual(after - baseline, 2, "A burst of reload requests must coalesce into one follow-up load")
        XCTAssertEqual(store.phase, .loaded)
    }

    func testRefreshFailureSurfacesInPhaseWithoutCrashingBoard() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        _ = try await seedTask(harness: harness, projectID: project.id, title: "Task", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        await harness.repository.failNextSnapshot(with: .underlying("snapshot unavailable"))
        await store.refresh()
        guard case .failed(let message) = store.phase else {
            XCTFail("Expected a failed phase, got \(store.phase)")
            return
        }
        XCTAssertTrue(message.contains("snapshot unavailable"))
        XCTAssertEqual(store.lastFailure, message)
    }
}

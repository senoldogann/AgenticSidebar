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

    func testConcurrentStartsAcrossTasksClaimOnceAndDeferTheOther() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let first = try await seedTask(harness: harness, projectID: project.id, title: "First", priority: 9, criteria: [])
        let second = try await seedTask(harness: harness, projectID: project.id, title: "Second", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        let gate = AsyncGate()
        await harness.repository.gateTaskReads(gate)
        let firstAction = Task { await store.start(taskID: first.id) }
        let secondAction = Task { await store.start(taskID: second.id) }
        await gate.waitUntilEntered(count: 2)
        await gate.release()

        let results = await [firstAction.value, secondAction.value]
        XCTAssertEqual(results.filter { $0 == .applied }.count, 1, "Exactly one start may hold the repository lease")
        let refusals = results.compactMap { result -> TaskBoardRefusal? in
            guard case .refused(let refusal) = result else { return nil }
            return refusal
        }
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.kind, .deferred)
        XCTAssertTrue(refusals.first?.message.contains("repositoryBusy") == true)

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 1)
        XCTAssertFalse(store.isActionInFlight(for: first.id))
        XCTAssertFalse(store.isActionInFlight(for: second.id))

        let snapshot = try await service.snapshot(projectID: project.id)
        XCTAssertEqual(snapshot.tasks.filter { $0.status == .running }.count, 1)
        XCTAssertEqual(snapshot.activeAttempts.count, 1)
    }

    func testDeferredStartRefusalUsesDedicatedDeferredKind() async throws {
        let harness = try ServiceTestHarness(workspace: .notOwned(reason: "no manifest"))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Deferred", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        let result = await store.start(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("A deferred start must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .deferred)
        XCTAssertTrue(refusal.message.contains("workspaceNotOwned"))
    }

    func testRepositoryBusyDeferredRefusalUsesDedicatedDeferredKind() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Busy repo", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        await harness.repository.failNextRepositoryLease(
            with: .repositoryLeaseConflict(
                repositoryPath: TaskBoardServiceFixtures.ownedWorkspace.repositoryPath,
                heldByTaskID: UUID()
            )
        )
        let result = await store.start(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("A busy repository must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .deferred)
        XCTAssertTrue(refusal.message.contains("repositoryBusy"))

        let counts = await harness.repository.mutationCounts()
        XCTAssertEqual(counts.claimAttempts, 0)
    }

    func testPersistenceSchedulerAndUnexpectedErrorsMapToRejectedKind() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Mapped", priority: 1, criteria: [])

        let persistence = TaskBoardStore.refusal(from: CodingTaskServiceError.persistence(.underlying("db down")))
        XCTAssertEqual(persistence.kind, .rejected)
        XCTAssertTrue(persistence.message.contains("db down"))
        let schedulerRejected = TaskBoardStore.refusal(
            from: CodingTaskServiceError.schedulerRejected(reason: "invalid completion outcome inProgress")
        )
        XCTAssertEqual(schedulerRejected.kind, .rejected)
        let unexpected = TaskBoardStore.refusal(from: CodingTaskServiceError.unexpected("CancellationError()"))
        XCTAssertEqual(unexpected.kind, .rejected)
        XCTAssertTrue(unexpected.message.contains("CancellationError()"))

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        await harness.repository.failNextTaskRead(with: TaskRepositoryError.underlying("db down"))
        let result = await store.start(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("A persistence failure must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .rejected)
        XCTAssertTrue(refusal.message.contains("db down"))
    }

    func testRefusalThenSuccessfulActionOnSameTaskClearsInFlight() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Retry after stale", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        _ = try await harness.store.transition(
            taskID: task.id,
            expectedVersion: 1,
            action: .markReady,
            context: TaskTransitionContext(fingerprint: "fixture", actor: "fixture")
        )
        let stale = await store.start(taskID: task.id)
        guard case .refused(let refusal) = stale else {
            XCTFail("A stale start must be refused, got \(stale)")
            return
        }
        XCTAssertEqual(refusal.kind, .stale)
        XCTAssertFalse(store.isActionInFlight(for: task.id))

        let card = try XCTUnwrap(store.cards.first { $0.id == task.id })
        XCTAssertEqual(card.status, .ready)
        XCTAssertEqual(card.version, 2)
        let result = await store.start(taskID: task.id)
        XCTAssertEqual(result, .applied)
        XCTAssertFalse(store.isActionInFlight(for: task.id))
        XCTAssertEqual(store.cards.first { $0.id == task.id }?.status, .running)
        XCTAssertTrue(store.actionAvailability(for: task.id).first { $0.action == .stop }?.isEnabled == true)
    }

    func testStaleStopAfterReviewAdvanceIsRefused() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "Stop", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()
        let startResult = await store.start(taskID: task.id)
        XCTAssertEqual(startResult, .applied)
        let running = try XCTUnwrap(store.cards.first { $0.id == task.id })
        XCTAssertEqual(running.status, .running)
        let attemptID = try XCTUnwrap(running.currentAttemptID)

        _ = try await harness.store.transition(
            taskID: task.id,
            expectedVersion: running.version,
            action: .submitForReview,
            context: TaskTransitionContext(fingerprint: attemptID.uuidString, actor: "agent", evidenceIDs: [UUID()])
        )

        let result = await store.stop(taskID: task.id)
        guard case .refused(let refusal) = result else {
            XCTFail("A stop of a review task must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .stale)
        let after = try XCTUnwrap(store.cards.first { $0.id == task.id })
        XCTAssertEqual(after.status, .review)
        let history = try await harness.store.attemptHistory(taskID: task.id)
        XCTAssertEqual(history.map(\.outcome), [.inProgress])
    }

    func testSelectionChangeDuringRefreshKeepsNewSelection() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let other = try await service.createProject(
            name: "Other",
            repositoryPath: "/tmp/agentic-sidebar-service-tests/other-repo",
            gitIdentity: "dev@example.com",
            protectedRefs: []
        )
        _ = try await seedTask(harness: harness, projectID: project.id, title: "Task", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()
        XCTAssertFalse(store.cards.isEmpty)

        let gate = AsyncGate()
        await harness.repository.gateSnapshots(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitUntilEntered()
        store.selectProject(other.id)
        await gate.release()
        await refresh.value

        XCTAssertEqual(store.selectedProjectID, other.id)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.detail)
        XCTAssertNil(store.selectedTaskID)
    }

    func testRefreshFailureWhileActionInFlightRecoversAfterAction() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let task = try await seedTask(harness: harness, projectID: project.id, title: "In flight", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        let gate = AsyncGate()
        await harness.repository.gateTaskReads(gate)
        let action = Task { await store.start(taskID: task.id) }
        await gate.waitUntilEntered()
        XCTAssertTrue(store.isActionInFlight(for: task.id))

        await harness.repository.failNextSnapshot(with: .underlying("snapshot unavailable"))
        await store.refresh()
        guard case .failed(let message) = store.phase else {
            XCTFail("Expected a failed phase, got \(store.phase)")
            return
        }
        XCTAssertTrue(message.contains("snapshot unavailable"))

        await gate.release()
        let result = await action.value
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertFalse(store.isActionInFlight(for: task.id))
        XCTAssertEqual(store.cards.first { $0.id == task.id }?.status, .running)
    }

    func testSelectingNewTaskClearsPreviousDetailLoadFailure() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let project = try await makeProject(service: service)
        let first = try await seedTask(harness: harness, projectID: project.id, title: "First", priority: 9, criteria: [])
        let second = try await seedTask(harness: harness, projectID: project.id, title: "Second", priority: 1, criteria: [])

        let store = TaskBoardStore(service: service)
        store.selectProject(project.id)
        await store.refresh()

        await harness.repository.failNextAttemptHistory(with: .underlying("history unavailable"))
        await store.selectTask(first.id)
        XCTAssertEqual(store.selectedTaskID, first.id)
        XCTAssertNotNil(store.lastFailure)

        await store.selectTask(second.id)
        XCTAssertEqual(store.selectedTaskID, second.id)
        XCTAssertNil(store.lastFailure, "A previous task's load failure must not leak onto the newly selected task")
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

    // MARK: - Proje kaydı

    /// En iyi çaba klasör denetiminden geçen geçici bir Git deposu klasörü:
    /// dizin ve içinde bir `.git` girdisi.
    private func makeRepositoryFolder(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-sidebar-store-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCreateProjectForwardsToServiceAndSelectsLoadedBoard() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let repositoryURL = try makeRepositoryFolder(name: "forwarding")
        let store = TaskBoardStore(service: service)
        var registeredProjectIDs: [UUID] = []
        store.onProjectRegistered = { registeredProjectIDs.append($0) }

        let result = await store.createProject(name: "Board Project", repositoryURL: repositoryURL)

        XCTAssertEqual(result, .applied)
        let projectID = try XCTUnwrap(store.selectedProjectID)
        let project = await service.project(id: projectID)
        XCTAssertEqual(project?.name, "Board Project")
        XCTAssertEqual(project?.repositoryPath, repositoryURL.path)
        XCTAssertFalse(project?.gitIdentity.isEmpty ?? true)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertNil(store.lastFailure)
        XCTAssertFalse(store.isCreatingProject)
        XCTAssertEqual(
            registeredProjectIDs,
            [projectID],
            "A successful registration must notify the composition registry exactly once"
        )
    }

    func testCreateProjectRefusesMissingFolderWithoutCallingService() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let store = TaskBoardStore(service: service)
        var registeredProjectIDs: [UUID] = []
        store.onProjectRegistered = { registeredProjectIDs.append($0) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-sidebar-missing-\(UUID().uuidString)",
            isDirectory: true
        )

        let result = await store.createProject(name: "Missing", repositoryURL: missing)

        guard case .refused(let refusal) = result else {
            XCTFail("A missing folder must be refused, got \(result)")
            return
        }
        XCTAssertEqual(refusal.kind, .rejected)
        XCTAssertTrue(refusal.message.contains("bulunamadı"))
        XCTAssertEqual(store.lastFailure, refusal.message)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(registeredProjectIDs.isEmpty, "A refused registration must never reach the registry")
    }

    func testCreateProjectRefusesBlankNameAndNonRepositoryFolder() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let store = TaskBoardStore(service: service)

        // Boş ad servise gider; servis doğrulaması reddi aynı kanaldan yüzeye
        // çıkar ve seçim değişmez.
        let repositoryURL = try makeRepositoryFolder(name: "blank-name")
        let blank = await store.createProject(name: "   ", repositoryURL: repositoryURL)
        guard case .refused(let blankRefusal) = blank else {
            XCTFail("A blank name must be refused, got \(blank)")
            return
        }
        XCTAssertEqual(blankRefusal.kind, .rejected)
        XCTAssertTrue(blankRefusal.message.contains("name"))
        XCTAssertEqual(store.lastFailure, blankRefusal.message)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.phase, .idle)

        // Git işareti taşımayan klasör servise hiç gönderilmez: en iyi çaba
        // klasör denetimi kullanıcıya formda geri bildirim verir.
        let plainFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-sidebar-non-repository-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plainFolder) }
        let nonRepository = await store.createProject(name: "Not a repository", repositoryURL: plainFolder)
        guard case .refused(let folderRefusal) = nonRepository else {
            XCTFail("A non-repository folder must be refused, got \(nonRepository)")
            return
        }
        XCTAssertEqual(folderRefusal.kind, .rejected)
        XCTAssertTrue(folderRefusal.message.contains("Git"))
        XCTAssertEqual(store.lastFailure, folderRefusal.message)
        XCTAssertNil(store.selectedProjectID)
    }

    func testProjectRegistrationPresenterDisablesSubmitUntilReady() {
        let repositoryURL = URL(fileURLWithPath: "/tmp/agentic-sidebar-board-project")

        XCTAssertFalse(
            TaskBoardProjectRegistrationPresenter.submitEnabled(
                name: "   ",
                repositoryURL: repositoryURL,
                isSubmitting: false
            )
        )
        XCTAssertFalse(
            TaskBoardProjectRegistrationPresenter.submitEnabled(
                name: "Board",
                repositoryURL: nil,
                isSubmitting: false
            )
        )
        XCTAssertFalse(
            TaskBoardProjectRegistrationPresenter.submitEnabled(
                name: "Board",
                repositoryURL: repositoryURL,
                isSubmitting: true
            )
        )
        XCTAssertTrue(
            TaskBoardProjectRegistrationPresenter.submitEnabled(
                name: "Board",
                repositoryURL: repositoryURL,
                isSubmitting: false
            )
        )
        XCTAssertEqual(
            TaskBoardProjectRegistrationPresenter.suggestedName(for: repositoryURL),
            "agentic-sidebar-board-project"
        )
    }
}

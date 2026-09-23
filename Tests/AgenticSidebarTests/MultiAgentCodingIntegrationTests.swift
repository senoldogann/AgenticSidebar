import Foundation
import XCTest

@testable import AgenticSidebar

/// Uçtan uca görev panosu koşusu: gerçek SQLite mağazası, gerçek zamanlayıcı,
/// gerçek kurtarma ve `TaskBoardComposition` kablolaması sahte sağlayıcı,
/// sahte çalışma alanı provizyonu ve gerçek küçük süreçler koşturan sahte
/// tarif adımlarıyla birlikte sınanır.
///
/// İki senaryo vardır:
/// 1. Mutlu yol: görev oluşturma → bağımlılık dayatması → bir deneme talebi →
///    sahte OpenCode olayları → sahte tarif kanıtı → eşleşen insan kabulü →
///    yeniden açılışta tek bir `done`.
/// 2. Çökme yolu: sağlayıcı düzenlemesi bildirildikten sonra kanıt yazılmadan
///    süreç ölür; yeniden açılışta `TaskRecovery.reconcile` görevi belirsiz
///    yürütme için engeller ve hiçbir yeni deneme açılmaz.
final class MultiAgentCodingIntegrationTests: XCTestCase {

    // MARK: - Step 1: mutlu yol

    @MainActor
    func testIntegratedRunRequiresMatchingAcceptanceAndPersistsDoneOnce() async throws {
        let root = try makeTemporaryRoot(name: "integrated-run")
        let dbURL = root.appendingPathComponent("taskboard.sqlite")
        let harness = try await IntegrationHarness.make(root: root, dbURL: dbURL)

        let project = try await harness.composition.service.createProject(
            name: "Integration",
            repositoryPath: harness.provisioning.repositoryPath,
            gitIdentity: "integration@agentic-sidebar.local",
            protectedRefs: ["main"]
        )

        // Bağımlılık dayatması: tamamlanmamış önkoşul, bağımlı görevi talep
        // turunun dışında tutar; pano kartı bekleyen önkoşulu açıkça gösterir.
        let prerequisite = try await harness.composition.service.createTask(
            projectID: project.id,
            title: "Prerequisite",
            objective: "Ship the prerequisite",
            priority: 1,
            criteria: ["prerequisite criterion"]
        )
        let dependent = try await harness.composition.service.createTask(
            projectID: project.id,
            title: "Dependent",
            objective: "Ship the dependent",
            priority: 2,
            criteria: ["dependent criterion"]
        )
        _ = try await harness.composition.service.addDependency(
            projectID: project.id,
            prerequisiteTaskID: prerequisite.id,
            dependentTaskID: dependent.id
        )
        _ = try await harness.repository.transition(
            taskID: dependent.id,
            expectedVersion: dependent.version,
            action: .markReady,
            context: TaskTransitionContext(fingerprint: "integration", actor: "integration")
        )

        let enforcementReport = try await harness.composition.scheduler.schedule(projectID: project.id)
        XCTAssertTrue(
            enforcementReport.claimedTaskIDs.isEmpty,
            "A claim pass must not dispatch a dependent task whose prerequisite is not done"
        )
        XCTAssertFalse(enforcementReport.claimedTaskIDs.contains(dependent.id))
        let enforcementCreateCount = await harness.provisioning.createCallCount
        XCTAssertEqual(
            enforcementCreateCount,
            0,
            "No workspace may be created while the prerequisite is unfinished"
        )

        harness.composition.store.selectProject(project.id)
        await harness.composition.store.refresh()
        let dependentCard = try XCTUnwrap(harness.composition.store.cards.first { $0.id == dependent.id })
        XCTAssertEqual(dependentCard.unmetPrerequisiteIDs, [prerequisite.id])

        // Mutlu yol görevi mağazadan tohumlanır: kabul ölçütü tamamlama yüzeyi
        // bu sürümde henüz bağlı olmadığından ölçüt, kabul kapısı testlerindeki
        // aynı tohumlama biçimiyle tamamlanmış olarak yazılır.
        let taskID = UUID()
        let now = harness.clock.now()
        try await harness.repository.createTask(
            CodingTask(
                id: taskID,
                projectID: project.id,
                title: "Integrated task",
                objective: "Reach done exactly once",
                priority: 5,
                status: .ready,
                stage: .plan,
                version: 1,
                criteria: [
                    CodingAcceptanceCriterion(
                        taskID: taskID,
                        description: "Integrated criterion",
                        isCompleted: true
                    )
                ],
                createdAt: now,
                updatedAt: now
            )
        )

        // İnsan yürütmeyi onaylar: start tek bir denemeyi sahipli çalışma
        // alanında talep eder.
        let startResult = try await harness.composition.service.start(taskID: taskID, expectedVersion: 1)
        guard case .claimed(let claimedAttemptID, let generation) = startResult else {
            XCTFail("Expected a claimed attempt, got \(startResult)")
            return
        }
        XCTAssertEqual(generation, 1)

        let claimedAttempts = try await harness.repository.attemptHistory(taskID: taskID)
        let claimedAttempt = try XCTUnwrap(claimedAttempts.first)
        XCTAssertEqual(claimedAttempt.outcome, .inProgress)
        XCTAssertEqual(claimedAttempt.id, claimedAttemptID)
        let workspaceID = try XCTUnwrap(claimedAttempt.workspaceID)
        let foundWorkspaceRecord = await harness.provisioning.record(for: workspaceID)
        let workspaceRecord = try XCTUnwrap(foundWorkspaceRecord)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspaceRecord.workspacePath + "/README.md"),
            "The disposable owned workspace must contain the committed fixture"
        )
        let claimCreateCount = await harness.provisioning.createCallCount
        XCTAssertEqual(claimCreateCount, 1)

        // Sahte OpenCode olayları: koşu terminal başarıyla biter ve bütün
        // olaylar talep edilen deneme kimliğini taşır.
        let runtime = FakeOpenCodeRuntime()
        let configuration = SessionConfiguration(
            providerID: ProviderID("opencode-fake"),
            modelID: ProviderModelID("fake-model"),
            variantID: nil
        )
        let run = try await runtime.start(
            request: CodingAgentExecutionRequest(
                taskID: taskID,
                attemptID: claimedAttemptID,
                generation: generation,
                role: .developer,
                configuration: configuration,
                objective: "Reach done exactly once",
                acceptanceCriteria: [],
                workspacePath: workspaceRecord.workspacePath,
                stage: .implementation
            )
        )
        var receivedEvents: [CodingAgentEvent] = []
        for await event in run.events {
            receivedEvents.append(event)
        }
        XCTAssertTrue(CodingAgentRun.isTerminatedSuccessfully(events: receivedEvents))
        XCTAssertFalse(receivedEvents.isEmpty)
        XCTAssertTrue(
            receivedEvents.allSatisfy { $0.matches(taskID: taskID, attemptID: claimedAttemptID, generation: generation) }
        )

        // Sağlayıcı düzenlemesi koşu sırasında işlenir; ardından tarif kanıtı
        // gerçek küçük süreçlerle üretilir.
        let editURL = URL(fileURLWithPath: workspaceRecord.workspacePath).appendingPathComponent("edit.txt")
        try Data("provider edit\n".utf8).write(to: editURL)

        let ownerNonce = try XCTUnwrap(claimedAttempt.leaseToken)
        let completion = try await harness.composition.scheduler.attemptDidComplete(
            taskID: taskID,
            attemptID: claimedAttemptID,
            generation: generation,
            ownerNonce: ownerNonce,
            outcome: .succeeded,
            usage: TaskAttemptUsage(toolCallCount: 1, durationSeconds: 42)
        )
        XCTAssertEqual(completion.disposition, .accepted)

        let fetchedReviewTask = try await harness.repository.task(id: taskID)
        let reviewTask = try XCTUnwrap(fetchedReviewTask)
        XCTAssertEqual(reviewTask.status, .review)
        XCTAssertEqual(reviewTask.currentAttemptID, claimedAttemptID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspaceRecord.workspacePath + "/artifacts/build.txt"),
            "The fake build step must have run as a real process"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspaceRecord.workspacePath + "/artifacts/test.txt"),
            "The fake test step must have run as a real process"
        )

        // Eşleşen insan kabulü: kanıt parmak izi güncel içerikle uyuşmazsa
        // kabul reddedilir; eşleşen kabul tek bir `done` üretir.
        let registeredFingerprint = await harness.ledger.registeredFingerprint(taskID: taskID)
        let recordedFingerprint = try XCTUnwrap(registeredFingerprint)
        XCTAssertFalse(recordedFingerprint.isEmpty)
        let readyDecision = try await harness.composition.service.evaluateAcceptance(taskID: taskID)
        XCTAssertEqual(readyDecision, .readyForHumanReview)

        await harness.ledger.setCurrentFingerprint("changed-content", taskID: taskID)
        let staleDecision = try await harness.composition.service.evaluateAcceptance(taskID: taskID)
        guard case .blocked(let staleReasons) = staleDecision else {
            XCTFail("A changed content fingerprint must deny acceptance, got \(staleDecision)")
            return
        }
        XCTAssertTrue(
            staleReasons.contains { reason in
                if case .requiredStepFingerprintMismatch = reason { return true }
                return false
            })

        do {
            _ = try await harness.composition.service.accept(
                taskID: taskID,
                expectedVersion: reviewTask.version,
                actor: "integration-user"
            )
            XCTFail("Acceptance must be denied while evidence fingerprints do not match current content")
        } catch let error as CodingTaskServiceError {
            guard case .acceptanceDenied(let deniedTaskID, let reasons) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(deniedTaskID, taskID)
            XCTAssertFalse(reasons.isEmpty)
        }
        let fetchedStillReview = try await harness.repository.task(id: taskID)
        let stillReview = try XCTUnwrap(fetchedStillReview)
        XCTAssertEqual(stillReview.status, .review)

        await harness.ledger.setCurrentFingerprint(recordedFingerprint, taskID: taskID)
        let accepted = try await harness.composition.service.accept(
            taskID: taskID,
            expectedVersion: reviewTask.version,
            actor: "integration-user"
        )
        XCTAssertEqual(accepted.status, .done)

        let approvals = try await harness.repository.approvals(taskID: taskID)
        XCTAssertEqual(approvals.count, 1)
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(approval.action, .accept)
        XCTAssertEqual(approval.actor, "integration-user")
        XCTAssertEqual(approval.attemptID, claimedAttemptID)
        XCTAssertEqual(approval.fingerprint, recordedFingerprint)
        let evidenceIDs = await harness.ledger.evidenceIDs(taskID: taskID)
        XCTAssertFalse(evidenceIDs.isEmpty)

        await harness.composition.store.refresh()
        let doneCard = try XCTUnwrap(harness.composition.store.cards.first { $0.id == taskID })
        XCTAssertEqual(doneCard.status, .done)
        let acceptAvailability = try XCTUnwrap(
            harness.composition.store.actionAvailability(for: taskID).first { $0.action == .accept }
        )
        XCTAssertFalse(acceptAvailability.isEnabled)

        // Yeniden açılış: durum, kanıt ve tek onay kalıcıdır; `done` ikinci
        // kez üretilemez.
        await harness.repository.close()

        let relaunch = try await IntegrationHarness.make(root: root, dbURL: dbURL)
        let fetchedPersistedTask = try await relaunch.repository.task(id: taskID)
        let persistedTask = try XCTUnwrap(fetchedPersistedTask)
        XCTAssertEqual(persistedTask.status, .done)
        XCTAssertEqual(persistedTask.currentAttemptID, claimedAttemptID)
        let persistedAttempts = try await relaunch.repository.attemptHistory(taskID: taskID)
        XCTAssertEqual(persistedAttempts.count, 1)
        XCTAssertEqual(persistedAttempts.first?.outcome, .succeeded)
        let relaunchedApprovals = try await relaunch.repository.approvals(taskID: taskID)
        XCTAssertEqual(relaunchedApprovals.count, 1)
        for evidenceID in evidenceIDs {
            let evidence = try await relaunch.repository.evidence(id: evidenceID)
            XCTAssertEqual(evidence?.taskID, taskID)
        }

        do {
            _ = try await relaunch.composition.service.accept(
                taskID: taskID,
                expectedVersion: persistedTask.version,
                actor: "integration-user"
            )
            XCTFail("A second accept must be refused: done is produced exactly once")
        } catch let error as CodingTaskServiceError {
            XCTAssertEqual(error, .actionNotAvailable(taskID: taskID, status: .done))
        }
        let finalSchedule = try await relaunch.composition.scheduler.schedule(projectID: project.id)
        XCTAssertTrue(finalSchedule.claimedTaskIDs.isEmpty)
        let finalAttempts = try await relaunch.repository.attemptHistory(taskID: taskID)
        XCTAssertEqual(finalAttempts.count, 1)
        await relaunch.repository.close()
    }

    // MARK: - Step 2: çökme ve kurtarma

    @MainActor
    func testCrashAfterProviderEditBlocksUncertainOnRelaunchWithoutDuplicateAttempt() async throws {
        let root = try makeTemporaryRoot(name: "crash-recovery")
        let dbURL = root.appendingPathComponent("taskboard.sqlite")

        let first = try await IntegrationHarness.make(root: root, dbURL: dbURL)
        let project = try await first.composition.service.createProject(
            name: "Crash",
            repositoryPath: first.provisioning.repositoryPath,
            gitIdentity: "integration@agentic-sidebar.local",
            protectedRefs: ["main"]
        )
        let taskID = UUID()
        let now = first.clock.now()
        try await first.repository.createTask(
            CodingTask(
                id: taskID,
                projectID: project.id,
                title: "Crash task",
                objective: "Survive a crash before evidence persistence",
                priority: 1,
                status: .ready,
                stage: .plan,
                version: 1,
                criteria: [
                    CodingAcceptanceCriterion(
                        taskID: taskID,
                        description: "Crash criterion",
                        isCompleted: true
                    )
                ],
                createdAt: now,
                updatedAt: now
            )
        )

        let startResult = try await first.composition.service.start(taskID: taskID, expectedVersion: 1)
        guard case .claimed(let attemptID, let generation) = startResult else {
            XCTFail("Expected a claimed attempt, got \(startResult)")
            return
        }
        let claimedAttempts = try await first.repository.attemptHistory(taskID: taskID)
        let attempt = try XCTUnwrap(claimedAttempts.first)
        let workspaceID = try XCTUnwrap(attempt.workspaceID)
        let foundCrashRecord = await first.provisioning.record(for: workspaceID)
        let workspaceRecord = try XCTUnwrap(foundCrashRecord)

        let runtime = FakeOpenCodeRuntime()
        let configuration = SessionConfiguration(
            providerID: ProviderID("opencode-fake"),
            modelID: ProviderModelID("fake-model"),
            variantID: nil
        )
        let run = try await runtime.start(
            request: CodingAgentExecutionRequest(
                taskID: taskID,
                attemptID: attemptID,
                generation: generation,
                role: .developer,
                configuration: configuration,
                objective: "Survive a crash before evidence persistence",
                acceptanceCriteria: [],
                workspacePath: workspaceRecord.workspacePath,
                stage: .implementation
            )
        )
        var receivedEvents: [CodingAgentEvent] = []
        for await event in run.events {
            receivedEvents.append(event)
        }
        XCTAssertTrue(CodingAgentRun.isTerminatedSuccessfully(events: receivedEvents))

        // Sağlayıcı düzenlemeyi bildirdi; süreç kanıt yazılmadan ölür, bu
        // yüzden `attemptDidComplete` hiç çağrılmaz.
        let editURL = URL(fileURLWithPath: workspaceRecord.workspacePath).appendingPathComponent("edit.txt")
        let editContent = Data("half-written provider edit\n".utf8)
        try editContent.write(to: editURL)
        await first.repository.close()

        // Yeniden açılış: kurtarma, zamanlayıcı herhangi bir tur işlemeden
        // ÖNCE koşar.
        let relaunch = try await IntegrationHarness.make(root: root, dbURL: dbURL)
        let report = await relaunch.composition.reconcile(projectID: project.id)
        let entry = try XCTUnwrap(report.entry(for: taskID))
        XCTAssertEqual(
            entry.disposition,
            .reconciledAndReleased(
                attemptID: attemptID,
                generation: generation,
                repositoryPath: relaunch.provisioning.repositoryPath
            )
        )
        XCTAssertTrue(
            entry.userChoices.contains { choice in
                if case .retryTask(let choiceTaskID) = choice { return choiceTaskID == taskID }
                return false
            })

        let fetchedBlocked = try await relaunch.repository.task(id: taskID)
        let blocked = try XCTUnwrap(fetchedBlocked)
        XCTAssertEqual(blocked.status, .blocked)
        guard case .uncertainExecution = blocked.blockReason else {
            XCTFail("Recovery must block for uncertain execution, got \(String(describing: blocked.blockReason))")
            return
        }
        let recoveredHistory = try await relaunch.repository.attemptHistory(taskID: taskID)
        XCTAssertEqual(recoveredHistory.map(\.outcome), [.cancelled])
        XCTAssertEqual(recoveredHistory.count, 1)

        // Kopya yazma yok: engellenen görev talep edilmez, yeni çalışma alanı
        // açılmaz ve sağlayıcı düzenlemesi yerinde kalır.
        let scheduleAfterRecovery = try await relaunch.composition.scheduler.schedule(projectID: project.id)
        XCTAssertTrue(scheduleAfterRecovery.claimedTaskIDs.isEmpty)
        let recoveryCreateCount = await relaunch.provisioning.createCallCount
        XCTAssertEqual(recoveryCreateCount, 0)
        XCTAssertEqual(try Data(contentsOf: editURL), editContent)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspaceRecord.workspacePath + "/artifacts/build.txt"),
            "Recovery must never dispatch verification or writing"
        )

        // Yeniden başlatma yalnızca açık bir insan kararıdır; start reddedilir.
        do {
            _ = try await relaunch.composition.service.start(taskID: taskID, expectedVersion: blocked.version)
            XCTFail("A blocked uncertain task must not be restarted by start")
        } catch let error as CodingTaskServiceError {
            XCTAssertEqual(error, .actionNotAvailable(taskID: taskID, status: .blocked))
        }
        let scheduleAfterStartAttempt = try await relaunch.composition.scheduler.schedule(projectID: project.id)
        XCTAssertTrue(scheduleAfterStartAttempt.claimedTaskIDs.isEmpty)

        // İkinci yeniden açılış kendiliğinden iyileştirmez ya da yeniden
        // denemez.
        await relaunch.repository.close()
        let second = try await IntegrationHarness.make(root: root, dbURL: dbURL)
        let secondReport = await second.composition.reconcile(projectID: project.id)
        XCTAssertEqual(secondReport.entry(for: taskID)?.disposition, .noAction)
        let fetchedFinalTask = try await second.repository.task(id: taskID)
        let finalTask = try XCTUnwrap(fetchedFinalTask)
        XCTAssertEqual(finalTask.status, .blocked)
        let secondCreateCount = await second.provisioning.createCallCount
        XCTAssertEqual(secondCreateCount, 0)
        let finalAttempts = try await second.repository.attemptHistory(taskID: taskID)
        XCTAssertEqual(finalAttempts.count, 1)
        XCTAssertEqual(try Data(contentsOf: editURL), editContent)
        await second.repository.close()
    }

    // MARK: - Step 3: açılış uzlaştırması

    @MainActor
    func testLaunchReconciliationCoversKnownProjectsAndBlocksCrashOrphan() async throws {
        let root = try makeTemporaryRoot(name: "launch-reconciliation")
        let dbURL = root.appendingPathComponent("taskboard.sqlite")

        let first = try await IntegrationHarness.make(root: root, dbURL: dbURL)
        // Proje panonun kayıt yoluyla açılır: kompozisyon kayıt defteri bu
        // süreçte projeyi böyle tanır. Klasör denetimi kayıt anında fail-fast
        // verir; fixture deposuna Git işareti ve SwiftPM işareti konur.
        let repositoryURL = URL(fileURLWithPath: first.provisioning.repositoryPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "// swift-tools-version: 5.9\n".write(
            to: repositoryURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let registration = await first.composition.store.createProject(
            name: "Launch",
            repositoryURL: repositoryURL
        )
        XCTAssertEqual(registration, .applied)
        let projectID = try XCTUnwrap(first.composition.store.selectedProjectID)
        XCTAssertEqual(
            first.composition.knownProjectIDs,
            [projectID],
            "Registration must feed the process-lifetime registry through the store callback"
        )

        let taskID = UUID()
        let now = first.clock.now()
        try await first.repository.createTask(
            CodingTask(
                id: taskID,
                projectID: projectID,
                title: "Launch crash task",
                objective: "Survive a crash and get reconciled at launch",
                priority: 1,
                status: .ready,
                stage: .plan,
                version: 1,
                criteria: [],
                createdAt: now,
                updatedAt: now
            )
        )

        let startResult = try await first.composition.service.start(taskID: taskID, expectedVersion: 1)
        guard case .claimed(let attemptID, let generation) = startResult else {
            XCTFail("Expected a claimed attempt, got \(startResult)")
            return
        }
        let claimedAttempts = try await first.repository.attemptHistory(taskID: taskID)
        let attempt = try XCTUnwrap(claimedAttempts.first)
        let workspaceID = try XCTUnwrap(attempt.workspaceID)
        let foundRecord = await first.provisioning.record(for: workspaceID)
        let workspaceRecord = try XCTUnwrap(foundRecord)

        let runtime = FakeOpenCodeRuntime()
        let configuration = SessionConfiguration(
            providerID: ProviderID("opencode-fake"),
            modelID: ProviderModelID("fake-model"),
            variantID: nil
        )
        let run = try await runtime.start(
            request: CodingAgentExecutionRequest(
                taskID: taskID,
                attemptID: attemptID,
                generation: generation,
                role: .developer,
                configuration: configuration,
                objective: "Survive a crash and get reconciled at launch",
                acceptanceCriteria: [],
                workspacePath: workspaceRecord.workspacePath,
                stage: .implementation
            )
        )
        for await _ in run.events {}
        // Sağlayıcı düzenlemeyi bildirdi; süreç kanıt yazılmadan ölür.
        let editURL = URL(fileURLWithPath: workspaceRecord.workspacePath).appendingPathComponent("edit.txt")
        let editContent = Data("launch reconciliation provider edit\n".utf8)
        try editContent.write(to: editURL)
        await first.repository.close()

        // Taze süreç: proje listesi kalıcı depodan geri yüklenir, bu yüzden
        // açılış uzlaştırması kayıtlı projeyi kapsar ve çökme artığını kapatır.
        let relaunch = try await IntegrationHarness.make(root: root, dbURL: dbURL)
        let reports = await relaunch.composition.reconcileKnownProjects()
        XCTAssertEqual(reports.count, 1, "A fresh process must restore persisted projects")
        XCTAssertEqual(relaunch.composition.knownProjectIDs, [projectID])
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.projectID, projectID)
        XCTAssertNil(report.failure)
        let entry = try XCTUnwrap(report.entry(for: taskID))
        XCTAssertEqual(
            entry.disposition,
            .reconciledAndReleased(
                attemptID: attemptID,
                generation: generation,
                repositoryPath: relaunch.provisioning.repositoryPath
            )
        )

        let fetchedBlocked = try await relaunch.repository.task(id: taskID)
        let blocked = try XCTUnwrap(fetchedBlocked)
        XCTAssertEqual(blocked.status, .blocked)
        guard case .uncertainExecution = blocked.blockReason else {
            XCTFail("Launch reconciliation must block for uncertain execution, got \(String(describing: blocked.blockReason))")
            return
        }
        let recoveredHistory = try await relaunch.repository.attemptHistory(taskID: taskID)
        XCTAssertEqual(recoveredHistory.map(\.outcome), [.cancelled])
        XCTAssertEqual(recoveredHistory.count, 1)

        // Kopya yazma yok: engellenen görev ne zamanlayıcıdan ne start'tan
        // yeniden talep edilebilir; sağlayıcı düzenlemesi yerinde kalır.
        let scheduleAfterRecovery = try await relaunch.composition.scheduler.schedule(projectID: projectID)
        XCTAssertTrue(scheduleAfterRecovery.claimedTaskIDs.isEmpty)
        do {
            _ = try await relaunch.composition.service.start(taskID: taskID, expectedVersion: blocked.version)
            XCTFail("A blocked uncertain task must not be restarted by start")
        } catch let error as CodingTaskServiceError {
            XCTAssertEqual(error, .actionNotAvailable(taskID: taskID, status: .blocked))
        }
        let recoveryCreateCount = await relaunch.provisioning.createCallCount
        XCTAssertEqual(recoveryCreateCount, 0)
        XCTAssertEqual(try Data(contentsOf: editURL), editContent)
        await relaunch.repository.close()
    }

    // MARK: - Step 4: kapanış kapsamı

    @MainActor
    func testShutdownStopsRunningTasksInEveryKnownProject() async throws {
        let root = try makeTemporaryRoot(name: "shutdown-coverage")
        let dbURL = root.appendingPathComponent("taskboard.sqlite")
        let harness = try await IntegrationHarness.make(root: root, dbURL: dbURL)

        let selectedProject = try await harness.composition.service.createProject(
            name: "Selected",
            repositoryPath: harness.provisioning.repositoryPath,
            gitIdentity: "integration@agentic-sidebar.local",
            protectedRefs: ["main"]
        )
        let otherProject = try await harness.composition.service.createProject(
            name: "Other",
            repositoryPath: harness.provisioning.repositoryPath,
            gitIdentity: "integration@agentic-sidebar.local",
            protectedRefs: ["main"]
        )
        harness.composition.register(projectID: selectedProject.id)
        harness.composition.register(projectID: otherProject.id)
        harness.composition.store.selectProject(selectedProject.id)

        let selectedTask = try await seedReadyTask(
            in: harness,
            projectID: selectedProject.id,
            title: "Selected project task"
        )
        let otherTask = try await seedReadyTask(
            in: harness,
            projectID: otherProject.id,
            title: "Other project task"
        )
        let selectedStart = try await harness.composition.service.start(
            taskID: selectedTask.id,
            expectedVersion: selectedTask.version
        )
        guard case .claimed = selectedStart else {
            XCTFail("Expected a claimed attempt for the selected project, got \(selectedStart)")
            return
        }
        // İki proje aynı üst depoyu paylaştığından ikinci canlı talep depo
        // kirası yüzünden ertelenir. Kapanış kapsamı canlı talep akışına değil
        // kalıcı `running` durumuna baktığı için diğer projenin koşan denemesi
        // doğrudan mağaza üzerinden tohumlanır.
        let otherAttempt = TaskAttempt(
            taskID: otherTask.id,
            attemptSequence: 1,
            role: .developer,
            providerID: "integration-fake",
            modelID: "fake-model",
            workspaceID: UUID(),
            leaseOwner: "shutdown-fixture",
            leaseToken: "shutdown-fixture-token",
            leaseExpiry: Date().addingTimeInterval(300)
        )
        _ = try await harness.repository.claimAttempt(
            taskID: otherTask.id,
            expectedVersion: otherTask.version,
            attempt: otherAttempt
        )

        await harness.composition.shutdown()

        let reopened = try SQLiteTaskStore.open(at: dbURL)
        let selectedAfter = try await reopened.task(id: selectedTask.id)
        XCTAssertEqual(selectedAfter?.status, .blocked)
        XCTAssertEqual(selectedAfter?.blockReason, .custom(TaskScheduler.stoppedBlockReason))
        let otherAfter = try await reopened.task(id: otherTask.id)
        XCTAssertEqual(otherAfter?.status, .blocked)
        XCTAssertEqual(
            otherAfter?.blockReason,
            .custom(TaskScheduler.stoppedBlockReason),
            "Shutdown must stop running tasks in every known project, not only the selected one"
        )
        await reopened.close()
    }

    // MARK: - Step 5: canlı kompozisyon kablolaması

    @MainActor
    func testLiveCompositionWiresDispatchPortAndCapabilityFlag() async throws {
        XCTAssertTrue(TaskBoardComposition.liveDispatchCapabilityPresent)
        TaskBoardComposition.assertLiveDispatchPrecondition()

        let root = try makeTemporaryRoot(name: "live-composition")
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let composition = try XCTUnwrap(
            TaskBoardComposition.live(
                applicationSupportDirectory: appSupport,
                openCodeServerManager: IntegrationLiveServerManager(),
                openCodeTransport: IntegrationLiveTransport(),
                credentialStore: IntegrationLiveCredentialStore(),
                toolAuditLog: ToolAuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
                permissionApprovalCenter: PermissionApprovalCenter(
                    automaticReplyProvider: { _, _ in nil },
                    decisionTimeout: .milliseconds(50),
                    auditLog: nil
                ),
                sessionConfiguration: { nil }
            )
        )

        // Canlı gönderim çalışma alanına köklenmiş sunucu fabrikasıyla
        // kablolanmıştır: gönderim yolu sohbet sunucusuna değil, koşu başına
        // açılan sunucuya bağlanır. Fabrika hiçbir sunucuyu önceden açmaz.
        let workspaceServerFactory = try XCTUnwrap(composition.workspaceServerFactory)
        let activeWorkspaces = await workspaceServerFactory.activeWorkspacePaths()
        XCTAssertTrue(activeWorkspaces.isEmpty)

        // Gönderim portu enjekte edilmiştir: kapı, port yokluğundan değil
        // deneme kimliğinin yokluğundan reddeder. Port bağlı olmasaydı hata
        // `.dispatchDisabled` olurdu.
        do {
            _ = try await composition.scheduler.dispatch(
                taskID: UUID(),
                attemptID: UUID(),
                generation: 1,
                fingerprint: "live-wiring-fingerprint"
            )
            XCTFail("Dispatch without an active attempt must be refused")
        } catch let refusal as TaskDispatchRefusal {
            guard case .staleAttempt = refusal else {
                return XCTFail("Expected a stale-attempt refusal proving the port is wired, got \(refusal)")
            }
        }

        await composition.repository.close()
    }

    // MARK: - Fixture

    @MainActor
    private func seedReadyTask(
        in harness: IntegrationHarness,
        projectID: UUID,
        title: String
    ) async throws -> CodingTask {
        let taskID = UUID()
        let now = harness.clock.now()
        let task = CodingTask(
            id: taskID,
            projectID: projectID,
            title: title,
            objective: "Objective for \(title)",
            priority: 1,
            status: .ready,
            stage: .plan,
            version: 1,
            criteria: [],
            createdAt: now,
            updatedAt: now
        )
        try await harness.repository.createTask(task)
        return task
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-taskboard-integration-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

// MARK: - Harness

/// Tek bir "süreç" için bütün kompozisyon: gerçek mağaza, zamanlayıcı,
/// kurtarma ve servis; sahte sağlayıcı, provizyon, tarif yürütücüsü ve
/// kabul kanıtı defteri.
@MainActor
private struct IntegrationHarness {
    let dbURL: URL
    let repository: SQLiteTaskStore
    let ledger: IntegrationEvidenceLedger
    let provisioning: IntegrationWorkspaceProvisioning
    let registry: IntegrationProviderRegistry
    let clock: IntegrationClock
    let composition: TaskBoardComposition

    static func make(root: URL, dbURL: URL) async throws -> IntegrationHarness {
        let repository = try SQLiteTaskStore.open(at: dbURL)
        let clock = IntegrationClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = IntegrationProviderRegistry()
        let provisioning = try IntegrationWorkspaceProvisioning(root: root)
        let ledger = IntegrationEvidenceLedger()
        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 4_096,
            terminationGrace: 1,
            drainGrace: 1,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let verifier = IntegrationRecipeVerifier(
            runner: runner,
            repository: repository,
            ledger: ledger,
            requiredSteps: IntegrationRecipeVerifier.requiredSteps
        )
        let composition = TaskBoardComposition.make(
            repository: repository,
            providers: registry,
            workspacePreflight: IntegrationWorkspacePreflight(),
            provisioning: provisioning,
            dispatchPort: nil,
            recoveryProviders: IntegrationProviderSessions(status: .stopped),
            recoveryWorkspaces: IntegrationWorkspaceOwnership(
                status: .notActivelyOwned(repositoryPath: provisioning.repositoryPath)
            ),
            recoveryProcesses: IntegrationProcessOwnership(status: .absent),
            verifier: verifier,
            acceptanceEvidence: ledger,
            executionFingerprints: IntegrationExecutionFingerprints(),
            clock: clock,
            schedulerID: "integration-scheduler",
            recoveryID: "integration-recovery",
            requiredSteps: IntegrationRecipeVerifier.requiredSteps
        )
        return IntegrationHarness(
            dbURL: dbURL,
            repository: repository,
            ledger: ledger,
            provisioning: provisioning,
            registry: registry,
            clock: clock,
            composition: composition
        )
    }
}

// MARK: - Clock

private final class IntegrationClock: TaskSchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        self.current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }
}

// MARK: - Provider registry

private actor IntegrationProviderRegistry: TaskProviderRegistryPort {
    nonisolated let runtimeID = "opencode-fake"
    nonisolated let modelID = "fake-model"
    private(set) var candidateCallCount = 0

    func candidate(for task: CodingTask, stage: TaskStage) async -> TaskProviderCandidate {
        candidateCallCount += 1
        return .eligible(runtimeID: runtimeID, modelID: modelID)
    }
}

/// Sahte OpenCode olay akışı: başlar, bir düzenleme etkinliği bildirir, kullanım
/// raporlar ve terminal başarıyla biter.
private actor FakeOpenCodeRuntime: CodingAgentRuntime {
    nonisolated let runtimeID = "opencode-fake"

    func capabilities(configuration: SessionConfiguration) async -> CodingAgentCapabilities {
        [
            .textAnalysis, .workspaceRead, .workspaceWrite, .tools, .interactiveApproval,
            .sessionResume, .cancellable, .structuredEvents, .usageReporting,
        ]
    }

    func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun {
        let (stream, continuation) = AsyncStream<CodingAgentEvent>.makeStream()
        let kinds: [CodingAgentEvent.Kind] = [
            .started,
            .textDelta("Preparing the edit"),
            .activityStarted(id: "edit-1", title: "Edit README.md"),
            .activityUpdated(id: "edit-1", detail: "writing"),
            .activityFinished(id: "edit-1"),
            .usage(inputTokens: 12, outputTokens: 34),
            .terminalSuccess,
        ]
        for kind in kinds {
            continuation.yield(
                CodingAgentEvent(
                    taskID: request.taskID,
                    attemptID: request.attemptID,
                    generation: request.generation,
                    kind: kind
                )
            )
        }
        continuation.finish()
        return CodingAgentRun(events: stream, cancel: {})
    }

    func release(attemptID: UUID) async {}
}

// MARK: - Workspace ports

/// Provizyon yolu kullanıldığında ön kontrol hiçbir çalışma alanı sahiplenmez.
private struct IntegrationWorkspacePreflight: TaskWorkspacePreflightPort {
    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
        .notOwned(reason: "integration provisioning owns workspace creation")
    }
}

/// Tek kullanımlık, gerçek dosyalı çalışma alanları üretir: her çalışma alanı
/// başlatılmış gerçek bir Git deposudur, böylece gerçek doğrulama yürütücüsü
/// içerik parmak izini hesaplayabilir.
private actor IntegrationWorkspaceProvisioning: TaskWorkspaceProvisioningPort {
    nonisolated let repositoryPath: String
    private let root: URL
    private var records: [UUID: WorkspaceRecord] = [:]
    private(set) var createCallCount = 0
    private(set) var discardCallCount = 0

    init(root: URL) throws {
        self.root = root
        let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        // Fikstür deposunun dil beyanı: pano tür algısı burayı `.node`
        // sayar, kabul kapısı `["build", "test"]` bekler; bu, sahte tarifin
        // ürettiği adım adlarıyla (`IntegrationRecipeVerifier.requiredSteps`)
        // birebir örtüşür. İşaret yoksa proje `generic` düşer ve kapı boş
        // kalırdı — parmak-izi-eşleşmezliği iddiaları o zaman tutmazdı.
        try Data("{\"name\":\"integration-fixture\"}\n".utf8).write(
            to: repositoryURL.appendingPathComponent("package.json", isDirectory: false)
        )
        self.repositoryPath = repositoryURL.path
    }

    func resolveBase(for task: CodingTask) async throws -> WorkspaceBase {
        WorkspaceBase(commitSHA: String(repeating: "a", count: 40))
    }

    func create(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord {
        createCallCount += 1
        let workspaceURL =
            root
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(task.id.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try IntegrationGitFixture.makeWorkspace(at: workspaceURL)
        let record = WorkspaceRecord(
            workspaceID: UUID(),
            projectID: task.projectID,
            taskID: task.id,
            attemptID: attempt.id,
            repositoryPath: repositoryPath,
            workspacePath: workspaceURL.path,
            commonDirIdentity: "integration-common-dir",
            baseSHA: base.commitSHA,
            nonce: UUID().uuidString,
            createdAt: Date()
        )
        records[record.workspaceID] = record
        return record
    }

    func discardUnclaimed(workspaceID: UUID, attemptID: UUID) async throws {
        discardCallCount += 1
        guard let record = records.removeValue(forKey: workspaceID) else { return }
        try? FileManager.default.removeItem(atPath: record.workspacePath)
    }

    func record(for workspaceID: UUID) -> WorkspaceRecord? {
        records[workspaceID]
    }
}

/// Yeniden başlatılan süreçte canlı tutucu yoktur; kayıt boşta kalır.
private struct IntegrationWorkspaceOwnership: TaskWorkspaceOwnershipInspecting {
    let status: TaskWorkspaceOwnershipStatus

    func workspaceStatus(for attempt: TaskAttempt) async -> TaskWorkspaceOwnershipStatus {
        status
    }
}

private struct IntegrationProviderSessions: TaskProviderSessionInspecting {
    let status: TaskProviderSessionStatus

    func providerStatus(for attempt: TaskAttempt) async -> TaskProviderSessionStatus {
        status
    }
}

private struct IntegrationProcessOwnership: TaskProcessOwnershipInspecting {
    let status: TaskProcessOwnershipStatus

    func processStatus(for attempt: TaskAttempt) async -> TaskProcessOwnershipStatus {
        status
    }
}

// MARK: - Verification

/// Sahte tarifi gerçek `VerificationRunner` ile koşturur: adımlar çalışma
/// alanındaki gerçek küçük kabuk betikleridir ve `artifacts/` altına gerçek
/// dosya yazarlar; üretilen adım kanıtı görev/deneme kimliğiyle bağlanıp
/// mağazaya ve kabul defterine yazılır.
private struct IntegrationRecipeVerifier: TaskVerifying {
    static let requiredSteps = ["build", "test"]

    let runner: VerificationRunner
    let repository: any CodingTaskRepository
    let ledger: IntegrationEvidenceLedger
    let requiredSteps: [String]

    func verify(
        task: CodingTask,
        attempt: TaskAttempt,
        workspace: TaskWorkspaceDescriptor
    ) async -> TaskVerificationReport {
        let workspaceURL = URL(fileURLWithPath: workspace.workspacePath)
        let recipe = Self.recipe(workspace: workspaceURL)
        do {
            let raw = try await runner.verify(recipe: recipe, workspace: workspaceURL)
            let bound = raw.map { entry in
                VerificationEvidence(
                    id: entry.id,
                    taskID: task.id,
                    attemptID: attempt.id,
                    recipeName: entry.recipeName,
                    stepName: entry.stepName,
                    status: entry.status,
                    exitCode: entry.exitCode,
                    timedOut: entry.timedOut,
                    detailsRedacted: entry.detailsRedacted,
                    workspaceFingerprint: entry.workspaceFingerprint,
                    blockedBy: entry.blockedBy,
                    recordedAt: entry.recordedAt,
                    recipeVersion: entry.recipeVersion
                )
            }
            for entry in bound {
                try await repository.recordEvidence(entry)
            }
            await ledger.record(taskID: task.id, evidence: bound)
            let latestByStep = Dictionary(grouping: bound) { $0.stepName ?? "" }
                .mapValues { entries in entries.max { $0.recordedAt < $1.recordedAt } }
            let passed = requiredSteps.allSatisfy { name in
                guard let entry = latestByStep[name] ?? nil else { return false }
                return entry.status == .passed
            }
            return TaskVerificationReport(
                passed: passed,
                recipeName: recipe.name,
                detailsRedacted: passed ? "integration recipe passed" : "integration recipe failed"
            )
        } catch {
            return TaskVerificationReport(
                passed: false,
                recipeName: "integration:fake",
                detailsRedacted: "integration recipe could not run: \(error)"
            )
        }
    }

    private static func recipe(workspace: URL) -> VerificationRecipe {
        let scripts = workspace.appendingPathComponent("scripts", isDirectory: true)
        return VerificationRecipe(
            name: "integration:fake",
            version: VerificationRecipe.currentVersion,
            trustedSource: "integration test",
            steps: [
                VerificationStep(
                    name: "build",
                    executable: scripts.appendingPathComponent("build.sh").path,
                    arguments: [],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: 60,
                    required: true
                ),
                VerificationStep(
                    name: "test",
                    executable: scripts.appendingPathComponent("test.sh").path,
                    arguments: [],
                    relativeWorkingDirectory: ".",
                    timeoutSeconds: 60,
                    required: true
                ),
            ],
            skippedSteps: []
        )
    }
}

/// Süreç ömürlü kanıt defteri: kabul kapısına kanıtı ve güncel içerik parmak
/// izini verir. Gerçek üretimde yeniden başlatmada defter boşalır ve kabul
/// açık bir gerekçeyle reddedilir; bu testte parmak izi test tarafından
/// yönlendirilir ki eşleşmeyen içerik kabulü reddetsin.
private actor IntegrationEvidenceLedger: TaskAcceptanceEvidenceProviding {
    private var entries: [UUID: [VerificationEvidence]] = [:]
    private var fingerprints: [UUID: String] = [:]

    func record(taskID: UUID, evidence: [VerificationEvidence]) {
        entries[taskID, default: []].append(contentsOf: evidence)
        if let fingerprint = evidence.compactMap(\.workspaceFingerprint).last {
            fingerprints[taskID] = fingerprint
        }
    }

    func acceptanceEvidence(taskID: UUID) async throws -> TaskAcceptanceEvidence {
        guard let fingerprint = fingerprints[taskID], !fingerprint.isEmpty else {
            throw IntegrationEvidenceFailure.fingerprintUnavailable
        }
        return TaskAcceptanceEvidence(
            evidence: entries[taskID] ?? [],
            currentFingerprint: fingerprint
        )
    }

    func setCurrentFingerprint(_ fingerprint: String, taskID: UUID) {
        fingerprints[taskID] = fingerprint
    }

    func registeredFingerprint(taskID: UUID) -> String? {
        fingerprints[taskID]
    }

    func evidenceIDs(taskID: UUID) -> [UUID] {
        (entries[taskID] ?? []).map(\.id)
    }
}

private enum IntegrationEvidenceFailure: Error {
    case fingerprintUnavailable
}

// MARK: - Git fixture

/// Geçici çalışma alanını gerçek bir Git deposuna dönüştürür; `artifacts/`
/// yok sayılır, böylece adımların yazdığı dosyalar parmak izini değiştirmez.
private enum IntegrationGitFixture {
    struct ToolResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum FixtureError: Error {
        case gitFailed(arguments: [String], stderr: String)
    }

    static func makeWorkspace(at url: URL) throws {
        try runGit(["init", "-q", "-b", "main"], in: url)
        try runGit(["config", "user.email", "integration-tests@agentic-sidebar.local"], in: url)
        try runGit(["config", "user.name", "Integration Tests"], in: url)
        try Data("integrated\n".utf8).write(to: url.appendingPathComponent("README.md"))
        try Data("artifacts/\n.build/\n".utf8).write(to: url.appendingPathComponent(".gitignore"))
        let scripts = url.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try writeScript(
            "#!/bin/sh\nset -eu\nmkdir -p artifacts\nprintf 'build-ran\\n' > artifacts/build.txt\n",
            to: scripts.appendingPathComponent("build.sh")
        )
        try writeScript(
            "#!/bin/sh\nset -eu\nmkdir -p artifacts\nprintf 'test-ran\\n' > artifacts/test.txt\n",
            to: scripts.appendingPathComponent("test.sh")
        )
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-q", "-m", "initial"], in: url)
    }

    private static func writeScript(_ source: String, to url: URL) throws {
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = ToolResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        guard result.exitCode == 0 else {
            throw FixtureError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
        return result
    }
}

// MARK: - Canlı kompozisyon sahteleri

/// Canlı kompozisyon kurulumu için parmak izi sağlayıcısı; bu harness'ta hiçbir
/// koşu başlatılmadığından yalnızca sözleşmeyi karşılar.
struct IntegrationExecutionFingerprints: TaskExecutionFingerprintProviding {
    func executionFingerprint(projectID: UUID, taskID: UUID) async throws -> String {
        throw TaskExecutionFingerprintError.workspaceNotOwned(taskID: taskID, reason: "integration harness never dispatches")
    }
}

/// Ayakta bir yönetilen sunucu taklit eder; canlı kompozisyon kurulumu
/// bağlantıyı yalnızca saklar, hiçbir istek göndermez.
private struct IntegrationLiveServerManager: OpenCodeServerManaging {
    private var connection: OpenCodeServerConnection {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:51999")!,
            username: "opencode",
            password: "integration-live-password"
        )
    }

    func status() async -> OpenCodeServerStatus {
        .running(version: "integration", baseURL: connection.baseURL)
    }

    func start(computerUse: ComputerUseConfiguration?) async throws -> OpenCodeServerConnection {
        connection
    }

    func currentConnection() async -> OpenCodeServerConnection? {
        connection
    }

    func stop() async {}

    func workingDirectory() async -> URL? {
        URL(fileURLWithPath: "/tmp/integration-live-workspace")
    }
}

/// Canlı kompozisyon kurulumunda hiçbir HTTP çağrısı yapılmaz; çağrı gelirse
/// açıkça başarısız olur.
private struct IntegrationLiveTransport: OpenCodeTransport {
    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        throw ProviderRuntimeError.unavailable
    }

    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream {
        throw ProviderRuntimeError.unavailable
    }
}

private final class IntegrationLiveCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String] = [:]

    func contains(_ key: CredentialKey) throws -> Bool {
        lock.withLock { values[key] != nil }
    }

    func read(_ key: CredentialKey) throws -> String? {
        lock.withLock { values[key] }
    }

    func write(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key] = value }
    }

    func delete(_ key: CredentialKey) throws {
        lock.withLock { values[key] = nil }
    }
}

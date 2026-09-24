import Foundation
import XCTest

@testable import AgenticSidebar

// MARK: - Çözülebilirlik ön kontrolü (H1) ve başarısızlık kanıtı (H2)

final class VerificationPreflightTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-sidebar-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "VerificationPreflightTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
        return process.terminationStatus
    }

    /// Üretimdeki gibi gerçek bir Git çalışma alanı, ama proje işaretsiz:
    /// çözümleyici reddeder (`unrecognizedProject`), parmak izi okunabilir.
    private func makeGitWorkspaceWithoutMarkers() throws -> URL {
        let dir = try temporaryDirectory()
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "preflight-tests@agentic-sidebar.local"], in: dir)
        try runGit(["config", "user.name", "Preflight Tests"], in: dir)
        try write("tracked\n", to: dir.appendingPathComponent("tracked.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "initial"], in: dir)
        return dir
    }

    func testMissingDirectoryIsNotResolvable() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-sidebar-absent-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertFalse(VerificationResolver.isResolvable(repository: missing))
    }

    func testDirectoryWithoutPackageManifestIsNotResolvable() throws {
        XCTAssertFalse(VerificationResolver.isResolvable(repository: try temporaryDirectory()))
    }

    func testPackageWithoutExecutableProductIsNotResolvable() throws {
        let dir = try temporaryDirectory()
        try write(
            """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "Lib", targets: [.target(name: "Lib")])
            """,
            to: dir.appendingPathComponent("Package.swift")
        )
        XCTAssertFalse(VerificationResolver.isResolvable(repository: dir))
    }

    func testPackageWithExecutableProductIsResolvable() throws {
        let dir = try temporaryDirectory()
        try write(
            """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(
                name: "App",
                products: [.executable(name: "App", targets: ["App"])],
                targets: [.executableTarget(name: "App")]
            )
            """,
            to: dir.appendingPathComponent("Package.swift")
        )
        XCTAssertTrue(VerificationResolver.isResolvable(repository: dir))
    }

    func testSanitizerKeepsCodeAndDropsAbsolutePaths() {
        let failure = RecipeTaskVerifier.sanitizedResolutionFailure(
            VerificationResolverError.unrecognizedProject(
                path: "/Users/kimse/GizliProje",
                reason: "no recognized project marker (Package.swift)"
            )
        )

        XCTAssertEqual(failure.code, "VERIFICATION_UNRECOGNIZED_PROJECT")
        XCTAssertTrue(failure.message.contains("VERIFICATION_UNRECOGNIZED_PROJECT"))
        XCTAssertTrue(failure.message.contains("Package.swift"))
        XCTAssertFalse(failure.message.contains("/Users/kimse/GizliProje"))
        XCTAssertFalse(failure.message.contains("unrecognizedProject(path:"))
    }

    func testSanitizerFallsBackWithoutLeakingDetails() {
        struct Bozuk: Error {}
        let failure = RecipeTaskVerifier.sanitizedResolutionFailure(Bozuk())

        XCTAssertEqual(failure.code, "VERIFICATION_FAILED")
        XCTAssertFalse(failure.message.contains("Bozuk"))
    }

    // MARK: - Denetçi okuma uyarısı (M3)

    private struct ThrowingAcceptanceEvidence: TaskAcceptanceEvidenceProviding {
        func acceptanceEvidence(taskID: UUID) async throws -> TaskAcceptanceEvidence {
            throw TaskEvidenceLedgerError.evidenceNotLoadedInThisProcess
        }
    }

    /// M3: "henüz koşmadı" ile "yükleme patladı" aynı `nil` değildir; koşmuş
    /// görevin kaybolan girdisi `warning` ile yüzeye çıkar, koşmamış görevde
    /// yokluk normaldir ve uyarı üretilmez.
    final class InspectorWarningTests: XCTestCase {
        private func makeService(
            evidence: any TaskAcceptanceEvidenceProviding,
            harness: ServiceTestHarness
        ) -> CodingTaskService {
            let recovery = TaskRecovery(
                repository: harness.repository,
                providers: NoProviderSessions(),
                workspaces: NoWorkspaceOwnership(),
                processes: NoProcesses(),
                clock: harness.clock,
                recoveryID: "recovery-inspector-warning"
            )
            return CodingTaskService(
                repository: harness.repository,
                scheduler: harness.scheduler,
                recovery: recovery,
                providers: harness.providers,
                acceptanceEvidence: evidence,
                executionFingerprints: FixedExecutionFingerprints(fingerprint: "fingerprint-1", failure: nil, gate: nil),
                clock: harness.clock,
                requiredSteps: ["build"],
                liveDispatchAvailable: false
            )
        }

        func testInspectorWarnsWhenRanTaskEvidenceCannotLoad() async throws {
            let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
            let plain = harness.makeService()
            let project = try await plain.createProject(
                name: "Board",
                repositoryPath: "/tmp/agentic-sidebar-service-tests/repo",
                gitIdentity: "dev@example.com",
                protectedRefs: ["main"]
            )
            let seeded = try await harness.seedReviewTask(
                projectID: project.id,
                criteriaCompleted: true,
                evidence: []
            )
            let service = makeService(evidence: ThrowingAcceptanceEvidence(), harness: harness)

            let inputs = await service.inspectorInputs(taskID: seeded.task.id)

            XCTAssertNil(inputs.evidence)
            XCTAssertNotNil(inputs.workspaceID)
            XCTAssertNotNil(inputs.warning)
            XCTAssertTrue(inputs.warning?.contains("yeniden başlatıldı") == true)
        }

        func testInspectorStaysQuietForNeverRanTask() async throws {
            let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
            let plain = harness.makeService()
            let project = try await plain.createProject(
                name: "Board",
                repositoryPath: "/tmp/agentic-sidebar-service-tests/repo",
                gitIdentity: "dev@example.com",
                protectedRefs: ["main"]
            )
            let task = try await plain.createTask(
                projectID: project.id,
                title: "Task",
                objective: "Objective",
                priority: 1,
                criteria: []
            )
            let service = makeService(evidence: ThrowingAcceptanceEvidence(), harness: harness)

            let inputs = await service.inspectorInputs(taskID: task.id)

            XCTAssertNil(inputs.evidence)
            XCTAssertNil(inputs.warning)
        }
    }

    /// H2: çözümleme düşerse rapor `passed:false` döner, ham yol karta
    /// sızmaz ve başarısızlık kanıt satırı olarak mağazaya yazılır.
    /// İşaret de `.git` de taşımayan dizin gerçekten tanınmazdır; kanıt
    /// kalıcı mağazadan okunur (parmak izi üretilemeyen dizinde defter
    /// kanıtı veremez, mağaza verir).
    func testUnresolvableWorkspaceLeavesFailedEvidence() async throws {
        let workspaceDir = try temporaryDirectory()
        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_192,
            terminationGrace: 5,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let store = try SQLiteTaskStore.inMemory()
        let ledger = TaskEvidenceLedger(probe: WorkspaceFingerprintProbe(runner: runner))
        let verifier = RecipeTaskVerifier(
            resolver: VerificationResolver(toolchain: .detected()),
            runner: runner,
            repository: store,
            ledger: ledger
        )
        let taskID = UUID()
        let attemptID = UUID()
        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Görev",
            objective: "Amaç",
            priority: 1,
            status: .running,
            stage: .implementation,
            version: 1,
            criteria: [],
            currentAttemptID: attemptID,
            createdAt: Date(),
            updatedAt: Date()
        )
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: taskID,
            attemptSequence: 1,
            role: .developer,
            providerID: "runtime-1",
            modelID: "model-1",
            generation: 1,
            startedAt: Date()
        )
        let workspace = TaskWorkspaceDescriptor(
            workspaceID: UUID(),
            workspacePath: workspaceDir.path,
            repositoryPath: workspaceDir.path
        )

        // Kanıt satırı görev satırına bağlanır (FK): görev önce mağazada
        // olmalıdır, yoksa kayıt sessizce düşer ve mağaza okuması boş kalır.
        try await store.createTask(task)

        let report = await verifier.verify(task: task, attempt: attempt, workspace: workspace)

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.recipeName, "unresolved")
        XCTAssertTrue(report.detailsRedacted.contains("VERIFICATION_UNRECOGNIZED_PROJECT"))
        XCTAssertFalse(report.detailsRedacted.contains(workspaceDir.path))

        let evidence = try await store.evidence(taskID: taskID)
        XCTAssertEqual(evidence.count, 1)
        let entry = try XCTUnwrap(evidence.first)
        XCTAssertFalse(entry.passed)
        XCTAssertEqual(entry.blockedBy, "VERIFICATION_UNRECOGNIZED_PROJECT")
        XCTAssertEqual(entry.taskID, taskID)
        XCTAssertEqual(entry.attemptID, attemptID)
        await store.close()
    }

    /// İşaretsiz Git deposu artık `generic` tarifeyle doğrulanır: `snapshot`
    /// adımı parmak izini mühürler, rapor geçer, defter kanıtı verir.
    func testMarkerlessGitWorkspaceVerifiesWithGenericRecipe() async throws {
        let workspaceDir = try makeGitWorkspaceWithoutMarkers()
        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_192,
            terminationGrace: 5,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let store = try SQLiteTaskStore.inMemory()
        let ledger = TaskEvidenceLedger(probe: WorkspaceFingerprintProbe(runner: runner))
        let verifier = RecipeTaskVerifier(
            resolver: VerificationResolver(toolchain: .detected()),
            runner: runner,
            repository: store,
            ledger: ledger
        )
        let taskID = UUID()
        let attemptID = UUID()
        let task = CodingTask(
            id: taskID,
            projectID: UUID(),
            title: "Görev",
            objective: "Amaç",
            priority: 1,
            status: .running,
            stage: .implementation,
            version: 1,
            criteria: [],
            currentAttemptID: attemptID,
            createdAt: Date(),
            updatedAt: Date()
        )
        let attempt = TaskAttempt(
            id: attemptID,
            taskID: taskID,
            attemptSequence: 1,
            role: .developer,
            providerID: "runtime-1",
            modelID: "model-1",
            generation: 1,
            startedAt: Date()
        )
        let workspace = TaskWorkspaceDescriptor(
            workspaceID: UUID(),
            workspacePath: workspaceDir.path,
            repositoryPath: workspaceDir.path
        )

        // Kanıt satırı görev satırına bağlanır (FK): görev önce mağazada
        // olmalıdır, yoksa kayıt sessizce düşer ve rapor çözülememiş görünür.
        try await store.createTask(task)

        let report = await verifier.verify(task: task, attempt: attempt, workspace: workspace)

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.recipeName, "generic:git")

        let evidence = try await ledger.acceptanceEvidence(taskID: taskID)
        XCTAssertEqual(evidence.evidence.count, 1)
        let entry = try XCTUnwrap(evidence.evidence.first)
        XCTAssertTrue(entry.passed)
        XCTAssertEqual(entry.stepName, "snapshot")
        XCTAssertEqual(entry.taskID, taskID)
        XCTAssertEqual(entry.attemptID, attemptID)
        XCTAssertFalse(evidence.currentFingerprint.isEmpty)
        await store.close()
    }
}

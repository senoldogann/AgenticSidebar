import Foundation
import XCTest

@testable import AgenticSidebar

/// Çok-dilli görev panosu: tür algısı, dil tarifleri, tür-bazlı kabul
/// kapısı, tür kalıcılığı ve yeniden başlatmaya dayanıklı kanıt okuma.
///
/// Her dilde pano çalışmalıdır; SwiftPM'e özel kapılar kök nedendi.
/// Bu dosya yeni davranışı kilitler, mevcut SwiftPM testleri aynen korunur.
final class ProjectKindDetectionTests: XCTestCase {
    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-project-kind-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeToolchain(in directory: URL) throws -> VerificationToolchain {
        VerificationToolchain(
            swiftExecutable: try makeExecutable(named: "fake-swift", in: directory),
            swiftFormatExecutable: nil,
            installedSwiftFormatVersion: nil,
            nodeExecutable: try makeExecutable(named: "fake-node", in: directory),
            npmExecutable: try makeExecutable(named: "fake-npm", in: directory),
            pythonExecutable: try makeExecutable(named: "fake-python3", in: directory),
            pytestExecutable: nil,
            goExecutable: try makeExecutable(named: "fake-go", in: directory),
            cargoExecutable: try makeExecutable(named: "fake-cargo", in: directory)
        )
    }

    private let swiftPackageWithProduct = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "App",
            products: [.executable(name: "App", targets: ["App"])],
            targets: [.executableTarget(name: "App")]
        )
        """

    private func makeGitRepository(at url: URL) throws {
        let process = { (arguments: [String]) throws in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = arguments
            task.currentDirectoryURL = url
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0, "git \(arguments.joined(separator: " ")) must succeed")
        }
        try process(["init", "-b", "main"])
        try process(["config", "user.email", "kind-tests@agentic-sidebar.local"])
        try process(["config", "user.name", "Kind Tests"])
        try write("tracked\n", to: url.appendingPathComponent("tracked.txt"))
        try process(["add", "."])
        try process(["commit", "-m", "initial"])
    }

    private struct StubPreflight: TaskWorkspacePreflightPort {
        let result: TaskWorkspacePreflightResult
        func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult { result }
    }

    // MARK: - Tür algısı

    func testDetectorRecognizesEveryLanguageMarker() throws {
        let swiftpm = try temporaryDirectory()
        try write(swiftPackageWithProduct, to: swiftpm.appendingPathComponent("Package.swift"))
        XCTAssertEqual(ProjectKindDetector.detect(in: swiftpm), .swiftpm)

        let node = try temporaryDirectory()
        try write("{\"name\":\"app\"}", to: node.appendingPathComponent("package.json"))
        XCTAssertEqual(ProjectKindDetector.detect(in: node), .node)

        for marker in ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"] {
            let python = try temporaryDirectory()
            try write("# marker", to: python.appendingPathComponent(marker))
            XCTAssertEqual(
                ProjectKindDetector.detect(in: python), .python,
                "marker \(marker) must detect Python"
            )
        }

        let go = try temporaryDirectory()
        try write("module example.com/app\n\ngo 1.21\n", to: go.appendingPathComponent("go.mod"))
        XCTAssertEqual(ProjectKindDetector.detect(in: go), .go)

        let rust = try temporaryDirectory()
        try write("[package]\nname = \"app\"\n", to: rust.appendingPathComponent("Cargo.toml"))
        XCTAssertEqual(ProjectKindDetector.detect(in: rust), .rust)
    }

    func testDetectorPrefersSwiftPMOverOtherMarkers() throws {
        let dir = try temporaryDirectory()
        try write(swiftPackageWithProduct, to: dir.appendingPathComponent("Package.swift"))
        try write("{\"name\":\"app\"}", to: dir.appendingPathComponent("package.json"))
        XCTAssertEqual(ProjectKindDetector.detect(in: dir), .swiftpm)
    }

    func testDetectorFallsBackToGenericForGitWithoutMarkers() throws {
        let dir = try temporaryDirectory()
        try makeGitRepository(at: dir)
        XCTAssertEqual(ProjectKindDetector.detect(in: dir), .generic)
    }

    func testDetectorRefusesDirectoryWithoutMarkersOrGit() throws {
        XCTAssertNil(ProjectKindDetector.detect(in: try temporaryDirectory()))
        XCTAssertNil(
            ProjectKindDetector.detect(
                in: FileManager.default.temporaryDirectory.appendingPathComponent("yok-\(UUID().uuidString)")
            )
        )
    }

    func testIsResolvableCoversEveryKind() throws {
        let node = try temporaryDirectory()
        try write("{\"name\":\"app\"}", to: node.appendingPathComponent("package.json"))
        XCTAssertTrue(VerificationResolver.isResolvable(repository: node))

        let generic = try temporaryDirectory()
        try makeGitRepository(at: generic)
        XCTAssertTrue(VerificationResolver.isResolvable(repository: generic))

        XCTAssertFalse(VerificationResolver.isResolvable(repository: try temporaryDirectory()))
    }

    // MARK: - Dil tarifleri

    func testNodeRecipeUsesNpmBuildAndTest() async throws {
        let tools = try temporaryDirectory()
        let repo = try temporaryDirectory()
        try write("{\"name\":\"app\"}", to: repo.appendingPathComponent("package.json"))
        let resolver = VerificationResolver(toolchain: try makeToolchain(in: tools))

        let recipe = try await resolver.resolve(repository: repo)

        XCTAssertEqual(recipe.name, "node:package.json")
        XCTAssertEqual(recipe.steps.map(\.name), ["build", "test"])
        XCTAssertTrue(recipe.steps.allSatisfy(\.required))
        XCTAssertTrue(recipe.steps.allSatisfy { $0.executable.hasPrefix("/") })
    }

    func testPythonRecipeFallsBackToUnittestWithoutPytest() async throws {
        let tools = try temporaryDirectory()
        let repo = try temporaryDirectory()
        try write("[project]\nname = \"app\"\n", to: repo.appendingPathComponent("pyproject.toml"))
        let resolver = VerificationResolver(toolchain: try makeToolchain(in: tools))

        let recipe = try await resolver.resolve(repository: repo)

        XCTAssertEqual(recipe.steps.map(\.name), ["build", "test"])
        let test = try XCTUnwrap(recipe.steps.first { $0.name == "test" })
        XCTAssertTrue(test.arguments.contains("unittest"))
    }

    func testGoAndRustRecipesNameRequiredBuildAndTest() async throws {
        let tools = try temporaryDirectory()
        let toolchain = try makeToolchain(in: tools)
        let resolver = VerificationResolver(toolchain: toolchain)

        let go = try temporaryDirectory()
        try write("module example.com/app\n\ngo 1.21\n", to: go.appendingPathComponent("go.mod"))
        let goRecipe = try await resolver.resolve(repository: go)
        XCTAssertEqual(goRecipe.name, "go:go.mod")
        XCTAssertEqual(goRecipe.steps.map(\.name), ["build", "test"])

        let rust = try temporaryDirectory()
        try write("[package]\nname = \"app\"\n", to: rust.appendingPathComponent("Cargo.toml"))
        let rustRecipe = try await resolver.resolve(repository: rust)
        XCTAssertEqual(rustRecipe.name, "rust:Cargo.toml")
        XCTAssertEqual(rustRecipe.steps.map(\.name), ["build", "test"])
    }

    func testGenericRecipeBindsFingerprintWithSnapshotStep() async throws {
        let tools = try temporaryDirectory()
        let repo = try temporaryDirectory()
        try makeGitRepository(at: repo)
        let resolver = VerificationResolver(toolchain: try makeToolchain(in: tools))

        let recipe = try await resolver.resolve(repository: repo)

        XCTAssertEqual(recipe.name, "generic:git")
        XCTAssertEqual(recipe.steps.map(\.name), ["snapshot"])
        XCTAssertTrue(recipe.steps.allSatisfy(\.required))
    }

    func testMissingLanguageRuntimeRefusesResolution() async throws {
        let tools = try temporaryDirectory()
        let repo = try temporaryDirectory()
        try write("{\"name\":\"app\"}", to: repo.appendingPathComponent("package.json"))
        let resolver = VerificationResolver(
            toolchain: VerificationToolchain(
                swiftExecutable: try makeExecutable(named: "fake-swift", in: tools)
            )
        )

        do {
            _ = try await resolver.resolve(repository: repo)
            XCTFail("A Node project without npm must not resolve")
        } catch let error as VerificationResolverError {
            guard case .requiredToolUnavailable(let step, _) = error else {
                return XCTFail("unexpected resolver error: \(error)")
            }
            XCTAssertEqual(step, "build")
        }
    }

    // MARK: - Kabul kapısı tür eşlemesi

    func testAcceptanceGateRequiresBuildAndTestForLanguages() {
        for kind in [ProjectKind.swiftpm, .node, .python, .go, .rust] {
            XCTAssertEqual(
                AcceptanceGate.requiredSteps(for: kind), ["build", "test"],
                "\(kind) must gate on build and test"
            )
        }
        XCTAssertEqual(AcceptanceGate.requiredSteps(for: .generic), [])
    }

    // MARK: - Tür kalıcılığı

    func testCreateProjectDetectsNodeKind() async throws {
        let harness = try ServiceTestHarness(workspace: .owned(TaskBoardServiceFixtures.ownedWorkspace))
        let service = harness.makeService()
        let repo = try temporaryDirectory()
        try write("{\"name\":\"app\"}", to: repo.appendingPathComponent("package.json"))

        let project = try await service.createProject(
            name: "Node App",
            repositoryPath: repo.path,
            gitIdentity: "dev@example.com",
            protectedRefs: ["main"]
        )

        XCTAssertEqual(project.kind, .node)
        let reloaded = try await harness.store.loadProject(id: project.id)
        XCTAssertEqual(reloaded?.kind, .node)
    }

    func testLegacyProjectRowWithoutKindLoadsAsGeneric() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let project = CodingProject(
            name: "Legacy",
            repositoryPath: "/tmp/legacy",
            gitIdentity: "dev@example.com"
        )
        XCTAssertEqual(project.kind, .generic)
        try await store.saveProject(project)
        let reloaded = try await store.loadProject(id: project.id)
        XCTAssertEqual(reloaded?.kind, .generic)
        await store.close()
    }

    func testCodingProjectDecodesWithoutKindAsGeneric() throws {
        let payload = """
            {"id":"\(UUID().uuidString)","name":"Eski","repositoryPath":"/tmp/x","gitIdentity":"a@b","protectedRefs":[],"createdAt":1700000000}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CodingProject.self, from: payload)
        XCTAssertEqual(decoded.kind, .generic)
    }

    // MARK: - Yeniden başlatmaya dayanıklı kanıt okuma

    func testLedgerRepairsEvidenceFromStoreAfterRestart() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let project = CodingProject(name: "Board", repositoryPath: "/tmp/repo", gitIdentity: "dev@example.com")
        try await store.saveProject(project)
        let taskID = UUID()
        let attemptID = UUID()
        let now = Date()
        let task = CodingTask(
            id: taskID,
            projectID: project.id,
            title: "Görev",
            objective: "Amaç",
            priority: 1,
            status: .running,
            stage: .implementation,
            version: 1,
            criteria: [],
            currentAttemptID: attemptID,
            createdAt: now,
            updatedAt: now
        )
        try await store.createTask(task)
        let stored = VerificationEvidence(
            taskID: taskID,
            attemptID: attemptID,
            recipeName: "node:package.json",
            stepName: "test",
            status: .passed,
            detailsRedacted: "ok",
            workspaceFingerprint: "fp-1",
            recipeVersion: VerificationRecipe.currentVersion
        )
        try await store.recordEvidence(stored)

        let workspace = try temporaryDirectory()
        try makeGitRepository(at: workspace)
        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_192,
            terminationGrace: 5,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        // Yeniden başlatma simülasyonu: bellek boş, yalnız mağaza dolu.
        let restarted = TaskEvidenceLedger(
            probe: WorkspaceFingerprintProbe(runner: runner),
            repository: store,
            preflight: StubPreflight(
                result: .owned(
                    TaskWorkspaceDescriptor(
                        workspaceID: UUID(),
                        workspacePath: workspace.path,
                        repositoryPath: workspace.path
                    )
                )
            )
        )

        let inputs = try await restarted.acceptanceEvidence(taskID: taskID)

        XCTAssertEqual(inputs.evidence.count, 1)
        XCTAssertEqual(inputs.evidence.first?.stepName, "test")
        XCTAssertFalse(inputs.currentFingerprint.isEmpty)
        await store.close()
    }

    func testLedgerWithoutBackupWiringStillRefusesOpenly() async throws {
        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_192,
            terminationGrace: 5,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let ledger = TaskEvidenceLedger(probe: WorkspaceFingerprintProbe(runner: runner))

        do {
            _ = try await ledger.acceptanceEvidence(taskID: UUID())
            XCTFail("A ledger without memory or backup must refuse")
        } catch {
            XCTAssertTrue(error is TaskEvidenceLedgerError)
        }
    }
}

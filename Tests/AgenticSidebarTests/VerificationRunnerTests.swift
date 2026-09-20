import Foundation
import XCTest

@testable import AgenticSidebar

/// Bounded, ordered verification execution tests.
///
/// Every scenario runs real executables (`/usr/bin/true`, `/usr/bin/false`,
/// `/bin/echo`, `/usr/bin/tail`) against a disposable Git workspace in the process
/// temporary directory. A step may only be recorded as passed when its actual exit
/// code is zero and the workspace revision did not change between steps.
final class VerificationRunnerTests: XCTestCase {

    // MARK: - Test doubles

    /// Thread-safe result slot for a runner invocation driven from a background task.
    private final class EvidenceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [VerificationEvidence]?

        func store(_ evidence: [VerificationEvidence]) {
            lock.withLock { stored = evidence }
        }

        var evidence: [VerificationEvidence]? {
            lock.withLock { stored }
        }
    }

    // MARK: - Fixtures

    private struct ToolResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private enum FixtureError: Error {
        case toolFailed(executable: String, arguments: [String], stderr: String)
    }

    @discardableResult
    private func runTool(_ executable: String, _ arguments: [String], in directory: URL) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> ToolResult {
        let result = try runTool("/usr/bin/git", arguments, in: directory)
        guard result.exitCode == 0 else {
            throw FixtureError.toolFailed(executable: "git", arguments: arguments, stderr: result.stderr)
        }
        return result
    }

    /// Creates a clean, disposable Git workspace with one tracked file.
    private func makeWorkspace(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-verification-runner-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "user.email", "verification-tests@agentic-sidebar.local"], in: root)
        try runGit(["config", "user.name", "Verification Tests"], in: root)
        try Data("tracked\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-m", "initial"], in: root)
        return root
    }

    private func makeRunner(maxDetailsCharacters: Int = 4_096) -> VerificationRunner {
        VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: maxDetailsCharacters,
            terminationGrace: 1,
            drainGrace: 1,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
    }

    private func step(
        _ name: String,
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String = ".",
        timeout: TimeInterval = 30,
        required: Bool = true
    ) -> VerificationStep {
        VerificationStep(
            name: name,
            executable: executable,
            arguments: arguments,
            relativeWorkingDirectory: cwd,
            timeoutSeconds: timeout,
            required: required
        )
    }

    private func recipe(
        _ name: String = "fixture",
        steps: [VerificationStep],
        skipped: [VerificationStepSkip] = []
    ) -> VerificationRecipe {
        VerificationRecipe(
            name: name,
            version: 1,
            trustedSource: "test-fixture",
            steps: steps,
            skippedSteps: skipped
        )
    }

    // MARK: - Ordering and failure propagation

    func testRequiredBuildFailurePreventsDependentTestExecution() async throws {
        let workspace = try makeWorkspace(name: "build-failure")
        let runner = makeRunner()
        let build = step("build", "/usr/bin/false")
        let test = step("test", "/usr/bin/touch", ["ran-test"])

        let evidence = await runner.verify(recipe: recipe(steps: [build, test]), workspace: workspace)

        XCTAssertEqual(evidence.map(\.stepName), ["build", "test"])
        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertEqual(evidence[0].exitCode, 1)
        XCTAssertFalse(evidence[0].timedOut)
        XCTAssertEqual(evidence[1].status, .skipped)
        XCTAssertEqual(evidence[1].blockedBy, "build")
        XCTAssertNil(evidence[1].exitCode)
        XCTAssertFalse(evidence[1].passed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ran-test").path),
            "a dependent step must not run after a required step failed"
        )
        XCTAssertEqual(evidence[0].workspaceFingerprint, evidence[1].workspaceFingerprint)
        XCTAssertNotNil(evidence[0].workspaceFingerprint)
    }

    func testOptionalFailureDoesNotBlockDependentSteps() async throws {
        let workspace = try makeWorkspace(name: "optional-failure")
        let runner = makeRunner()
        let optional = step("format", "/usr/bin/false", required: false)
        let test = step("test", "/usr/bin/touch", ["ran-test"])

        let evidence = await runner.verify(recipe: recipe(steps: [optional, test]), workspace: workspace)

        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertFalse(evidence[0].passed)
        XCTAssertEqual(evidence[1].status, .passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ran-test").path))
    }

    func testNonzeroTestExitIsRecordedAsFailure() async throws {
        let workspace = try makeWorkspace(name: "test-nonzero")
        let runner = makeRunner()

        let evidence = await runner.verify(recipe: recipe(steps: [step("test", "/usr/bin/false")]), workspace: workspace)

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertEqual(evidence[0].exitCode, 1)
        XCTAssertFalse(evidence[0].passed)
        XCTAssertFalse(evidence[0].timedOut)
    }

    func testMissingRequiredLintIsRecordedAsFailureWithoutRunning() async throws {
        let workspace = try makeWorkspace(name: "missing-lint")
        let runner = makeRunner()
        let missing = "/usr/bin/agentic-missing-lint-\(UUID().uuidString)"

        let evidence = await runner.verify(
            recipe: recipe(steps: [step("format", missing, ["lint"])]),
            workspace: workspace
        )

        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertNil(evidence[0].exitCode)
        XCTAssertFalse(evidence[0].passed)
        XCTAssertTrue(evidence[0].detailsRedacted.contains("unavailable"), evidence[0].detailsRedacted)
    }

    // MARK: - Deadline and cancellation

    func testTimeoutIsBoundedAndRecorded() async throws {
        let workspace = try makeWorkspace(name: "timeout")
        let runner = makeRunner()
        let started = Date()

        let evidence = await runner.verify(
            recipe: recipe(steps: [step("hang", "/usr/bin/tail", ["-f", "/dev/null"], timeout: 0.5)]),
            workspace: workspace
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the runner must enforce its per-step deadline")
        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertTrue(evidence[0].timedOut)
        XCTAssertFalse(evidence[0].passed)

        var stray = try runTool("/usr/bin/pgrep", ["-f", "tail -f /dev/null"], in: workspace)
        let deadline = Date().addingTimeInterval(3)
        while stray.exitCode == 0, Date() < deadline {
            usleep(100_000)
            stray = try runTool("/usr/bin/pgrep", ["-f", "tail -f /dev/null"], in: workspace)
        }
        XCTAssertEqual(stray.exitCode, 1, "timed-out step left running: \(stray.stdout)")
    }

    func testCancellationStopsRemainingSteps() async throws {
        let workspace = try makeWorkspace(name: "cancellation")
        let runner = makeRunner()
        let hang = step("hang", "/usr/bin/tail", ["-f", "/dev/null"], timeout: 30)
        let dependent = step("dependent", "/usr/bin/touch", ["ran-dependent"])
        let box = EvidenceBox()
        let finished = DispatchSemaphore(value: 0)
        let hangRecipe = recipe(steps: [hang, dependent])

        Task {
            box.store(await runner.verify(recipe: hangRecipe, workspace: workspace))
            finished.signal()
        }

        try await Task.sleep(for: .milliseconds(500))
        await runner.cancel()

        XCTAssertEqual(
            finished.wait(timeout: .now() + 15),
            .success,
            "a cancelled verification must return within a bounded deadline"
        )
        let evidence = try XCTUnwrap(box.evidence)
        XCTAssertEqual(evidence.map(\.stepName), ["hang", "dependent"])
        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertFalse(evidence[0].passed)
        XCTAssertTrue(evidence[0].detailsRedacted.contains("cancel"), evidence[0].detailsRedacted)
        XCTAssertEqual(evidence[1].status, .skipped)
        XCTAssertEqual(evidence[1].blockedBy, "cancellation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ran-dependent").path))
    }

    // MARK: - Revision fingerprint

    func testFingerprintChangeBetweenStepsPreventsPass() async throws {
        let workspace = try makeWorkspace(name: "fingerprint-drift")
        let runner = makeRunner()
        let first = step("first", "/usr/bin/true")
        let mutate = step("mutate", "/bin/cp", ["/dev/null", "tracked.txt"])
        let after = step("after", "/usr/bin/true")

        let evidence = await runner.verify(recipe: recipe(steps: [first, mutate, after]), workspace: workspace)

        XCTAssertEqual(evidence[0].status, .passed)
        XCTAssertEqual(evidence[1].status, .passed)
        XCTAssertEqual(evidence[2].status, .skipped)
        XCTAssertEqual(evidence[2].blockedBy, "workspaceFingerprint")
        XCTAssertFalse(evidence[2].passed)
        XCTAssertTrue(evidence[2].detailsRedacted.contains("fingerprint"), evidence[2].detailsRedacted)
        XCTAssertNotEqual(evidence[1].workspaceFingerprint, evidence[2].workspaceFingerprint)
    }

    func testRunnerRefusesPassWithoutWorkspaceRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-verification-runner-plain-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runner = makeRunner()

        let evidence = await runner.verify(
            recipe: recipe(steps: [step("build", "/usr/bin/touch", ["ran-without-revision"])]),
            workspace: root
        )

        XCTAssertEqual(evidence[0].status, .failed)
        XCTAssertNil(evidence[0].workspaceFingerprint)
        XCTAssertFalse(evidence[0].passed)
        XCTAssertTrue(evidence[0].detailsRedacted.contains("fingerprint"), evidence[0].detailsRedacted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran-without-revision").path))
    }

    // MARK: - Output handling

    func testRunnerRedactsSecretsInRecordedOutput() async throws {
        let workspace = try makeWorkspace(name: "redaction")
        let runner = makeRunner()

        let evidence = await runner.verify(
            recipe: recipe(steps: [step("echo", "/bin/echo", ["token=supersecretvalue123", "Bearer abcdefghijklmnopqrstuvwxyz"])]),
            workspace: workspace
        )

        XCTAssertEqual(evidence[0].status, .passed)
        XCTAssertFalse(evidence[0].detailsRedacted.contains("supersecretvalue123"))
        XCTAssertTrue(evidence[0].detailsRedacted.contains("<redacted>"), evidence[0].detailsRedacted)
    }

    func testRunnerClipsNoisyOutput() async throws {
        let workspace = try makeWorkspace(name: "clipping")
        let runner = makeRunner(maxDetailsCharacters: 512)

        let evidence = await runner.verify(
            recipe: recipe(steps: [step("noisy", "/usr/bin/seq", ["1", "200000"])]),
            workspace: workspace
        )

        XCTAssertEqual(evidence[0].status, .passed)
        XCTAssertLessThanOrEqual(evidence[0].detailsRedacted.count, 528)
        XCTAssertTrue(evidence[0].detailsRedacted.contains("[clipped]"), evidence[0].detailsRedacted)
    }

    func testSkippedRecipeStepsAreRecordedExplicitly() async throws {
        let workspace = try makeWorkspace(name: "skipped")
        let runner = makeRunner()
        let skip = VerificationStepSkip(
            name: "format",
            reason: "swift-format 604.0.0 required; installed 603.0.0"
        )

        let evidence = await runner.verify(
            recipe: recipe(steps: [step("build", "/usr/bin/true")], skipped: [skip]),
            workspace: workspace
        )

        XCTAssertEqual(evidence.map(\.stepName), ["build", "format"])
        XCTAssertEqual(evidence[1].status, .skipped)
        XCTAssertFalse(evidence[1].passed)
        XCTAssertNil(evidence[1].exitCode)
        XCTAssertTrue(evidence[1].detailsRedacted.contains("603.0.0"), evidence[1].detailsRedacted)
    }

    // MARK: - Persistence

    func testRunnerEvidenceRoundTripsThroughTaskStore() async throws {
        let store = try SQLiteTaskStore.inMemory()
        let task = CodingTask(projectID: UUID(), title: "Verification", objective: "Round-trip evidence")
        try await store.createTask(task)
        let attemptID = UUID()
        // SQLite stores the timestamp as REAL; an integral second round-trips exactly.
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let taskEvidence = VerificationEvidence(
            taskID: task.id,
            attemptID: attemptID,
            recipeName: "swiftpm:AgenticSidebar",
            stepName: "build",
            status: .failed,
            exitCode: 1,
            timedOut: false,
            detailsRedacted: "step=build exit=1",
            workspaceFingerprint: "head=abc;status=def",
            blockedBy: nil,
            recordedAt: recordedAt
        )
        try await store.recordEvidence(taskEvidence)
        let loadedTaskEvidence = try await store.evidence(id: taskEvidence.id)
        XCTAssertEqual(loadedTaskEvidence, taskEvidence)

        // Standalone runner evidence carries no task identity until it is attached.
        let standalone = VerificationEvidence(
            recipeName: "swiftpm:AgenticSidebar",
            stepName: "format",
            status: .skipped,
            exitCode: nil,
            timedOut: false,
            detailsRedacted: "swift-format unavailable",
            workspaceFingerprint: "head=abc;status=def",
            blockedBy: "build",
            recordedAt: recordedAt
        )
        try await store.recordEvidence(standalone)
        let loadedStandalone = try await store.evidence(id: standalone.id)
        XCTAssertEqual(loadedStandalone, standalone)
        let missing = try await store.evidence(id: UUID())
        XCTAssertNil(missing)
        await store.close()
    }

    // MARK: - Real-host smoke

    private struct SmokeProjectResolver: WorkspaceProjectResolving {
        let projects: [CodingProject]

        func resolveProject(id: UUID) async -> CodingProject? {
            projects.first { $0.id == id }
        }
    }

    /// Opt-in real-host smoke: resolves this repository's trusted recipe, creates a
    /// disposable managed worktree from a clean clone of the committed revision and runs
    /// the fast subset (build plus formatter gate) against it.
    ///
    /// Skipped unless `RUN_VERIFICATION_SMOKE=1` so the hermetic suite stays fast. The
    /// live checkout may carry unrelated uncommitted work, so the managed workspace is
    /// created from a clean clone; no raw `git worktree` command bypasses the port.
    func testRealHostRecipeSmokeOnDisposableManagedWorktree() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_VERIFICATION_SMOKE"] == "1",
            "Set RUN_VERIFICATION_SMOKE=1 to run the real-host verification smoke"
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let resolver = VerificationResolver(toolchain: .detected())
        let recipe = try await resolver.resolve(repository: repositoryRoot)
        XCTAssertEqual(recipe.name, "swiftpm:AgenticSidebar")
        XCTAssertEqual(recipe.steps.map(\.name), ["build", "test", "format"])
        XCTAssertTrue(recipe.skippedSteps.isEmpty, "the host toolchain must match the repository pin: \(recipe.skippedSteps)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-verification-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let cloneURL = root.appendingPathComponent("repo", isDirectory: true)
        let clone = try runTool(
            "/usr/bin/git",
            ["clone", "--quiet", "--no-hardlinks", repositoryRoot.path, cloneURL.path],
            in: root
        )
        XCTAssertEqual(clone.exitCode, 0, clone.stderr)
        let head = try runGit(["rev-parse", "HEAD"], in: cloneURL).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let project = CodingProject(
            name: "AgenticSidebar",
            repositoryPath: cloneURL.path,
            gitIdentity: "verification-smoke"
        )
        let task = CodingTask(projectID: project.id, title: "Verification smoke", objective: "Run the trusted recipe subset")
        let attempt = TaskAttempt(
            taskID: task.id,
            attemptSequence: 1,
            role: .qa,
            providerID: "verification-smoke",
            modelID: "host",
            generation: 1
        )
        let manager = GitWorkspaceManager(
            runner: GitCommandRunner(executableDirectory: URL(fileURLWithPath: "/usr/bin"), maxOutputBytes: 262_144),
            projects: SmokeProjectResolver(projects: [project]),
            events: nil,
            configuration: WorkspaceManagerConfiguration(
                authorizedRoot: root.appendingPathComponent("managed", isDirectory: true),
                authorizedProjectRoots: [root]
            )
        )

        let record = try await manager.createOwnedWorkspace(task: task, attempt: attempt, base: WorkspaceBase(commitSHA: head))
        let workspaceURL = URL(fileURLWithPath: record.workspacePath)

        let subset = VerificationRecipe(
            name: recipe.name + ":smoke-subset",
            version: recipe.version,
            trustedSource: recipe.trustedSource,
            steps: recipe.steps.filter { $0.name == "build" || $0.name == "format" },
            skippedSteps: []
        )
        let runner = VerificationRunner(
            maxOutputBytes: 262_144,
            maxDetailsCharacters: 8_000,
            terminationGrace: 2,
            drainGrace: 2,
            gitExecutableDirectory: URL(fileURLWithPath: "/usr/bin")
        )
        let evidence = await runner.verify(recipe: subset, workspace: workspaceURL)

        for entry in evidence {
            print(
                "[verification-smoke] step=\(entry.stepName ?? "?") status=\(entry.status.rawValue) "
                    + "exit=\(entry.exitCode.map(String.init) ?? "none") timedOut=\(entry.timedOut) "
                    + "fingerprint=\(entry.workspaceFingerprint ?? "none") blockedBy=\(entry.blockedBy ?? "none")"
            )
            print("[verification-smoke] details:\n\(entry.detailsRedacted)")
        }

        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(evidence[0].stepName, "build")
        XCTAssertEqual(evidence[0].status, .passed)
        XCTAssertEqual(evidence[0].exitCode, 0)
        XCTAssertFalse(evidence[0].timedOut)
        XCTAssertEqual(evidence[1].stepName, "format")
        XCTAssertEqual(evidence[1].status, .passed)
        XCTAssertEqual(evidence[1].exitCode, 0)
        XCTAssertEqual(evidence[0].workspaceFingerprint, evidence[1].workspaceFingerprint)
        XCTAssertNotNil(evidence[0].workspaceFingerprint)

        // Cleanup through the managed port only; no raw worktree mutation.
        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)
        try await manager.retire(
            workspaceID: record.workspaceID,
            approval: TaskApproval(
                taskID: task.id,
                attemptID: attempt.id,
                fingerprint: head,
                actor: "verification-smoke",
                action: .discardWorkspace
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: record.workspacePath), "orphaned worktree directory")
        let worktrees = try runGit(["worktree", "list", "--porcelain"], in: cloneURL).stdout
        XCTAssertFalse(worktrees.contains(record.workspacePath), "orphaned worktree registration: \(worktrees)")
        let stray = try runTool("/usr/bin/pgrep", ["-f", record.workspacePath], in: root)
        XCTAssertEqual(stray.exitCode, 1, "orphaned verification process: \(stray.stdout)")
    }
}

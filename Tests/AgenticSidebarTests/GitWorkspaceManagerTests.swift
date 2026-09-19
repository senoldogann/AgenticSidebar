import Foundation
import XCTest

@testable import AgenticSidebar

/// Guard, provenance and retirement tests for the managed Git worktree layer.
///
/// Every fixture is a disposable repository under the process temporary directory.
/// The helpers below never run `git worktree` mutations; all worktree lifecycle
/// operations go through `GitWorkspaceManager` so no raw path can bypass a guard.
final class GitWorkspaceManagerTests: XCTestCase {

    // MARK: - Test doubles

    private struct StaticProjectResolver: WorkspaceProjectResolving {
        let projects: [CodingProject]

        func resolveProject(id: UUID) async -> CodingProject? {
            projects.first { $0.id == id }
        }
    }

    private struct StaticTaskResolver: CodingTaskResolving {
        let tasks: [CodingTask]

        func resolveTask(id: UUID) async -> CodingTask? {
            tasks.first { $0.id == id }
        }
    }

    private enum SpyFailure: Error, Equatable {
        case storeUnavailable
    }

    private final class RecordingWorkspaceEvents: WorkspaceEventRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CodingTaskEvent] = []
        private let failure: SpyFailure?

        init(failure: SpyFailure?) {
            self.failure = failure
        }

        var events: [CodingTaskEvent] {
            lock.withLock { stored }
        }

        func recordWorkspaceEvent(_ event: CodingTaskEvent) async throws {
            if let failure {
                throw failure
            }
            lock.withLock { stored.append(event) }
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let projectsRoot: URL
        let authorizedRoot: URL
        let repositoryURL: URL
        let baseSHA: String
    }

    private struct ToolResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private enum FixtureError: Error {
        case gitFailed(arguments: [String], stderr: String)
    }

    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func canonical(_ url: URL) -> String {
        url.standardized.resolvingSymlinksInPath().path
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
    }

    @discardableResult
    private func runTool(_ executable: String, _ arguments: [String], in directory: URL) throws -> ToolResult {
        let process = Process()
        let executablePath = executable.hasPrefix("/") ? executable : "/usr/bin/\(executable)"
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
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
        let result = try runTool("git", arguments, in: directory)
        guard result.exitCode == 0 else {
            throw FixtureError.gitFailed(arguments: arguments, stderr: result.stderr)
        }
        return result
    }

    /// Creates a clean fixture repository on `feature/task` with an ignored artifact.
    private func makeCleanFixture(name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentic-workspace-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let repositoryURL = projectsRoot.appendingPathComponent("repo", isDirectory: true)
        let authorizedRoot = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-b", "main"], in: repositoryURL)
        try runGit(["config", "user.email", "workspace-tests@agentic-sidebar.local"], in: repositoryURL)
        try runGit(["config", "user.name", "Workspace Tests"], in: repositoryURL)
        try Data("tracked\n".utf8).write(to: repositoryURL.appendingPathComponent("README.md"))
        try Data(".build/\n".utf8).write(to: repositoryURL.appendingPathComponent(".gitignore"))
        try runGit(["add", "."], in: repositoryURL)
        try runGit(["commit", "-m", "initial"], in: repositoryURL)
        let baseSHA = try runGit(["rev-parse", "HEAD"], in: repositoryURL).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["switch", "-c", "feature/task"], in: repositoryURL)
        let ignoredDirectory = repositoryURL.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: ignoredDirectory.appendingPathComponent("artifact.bin"))

        return Fixture(
            root: root,
            projectsRoot: projectsRoot,
            authorizedRoot: authorizedRoot,
            repositoryURL: repositoryURL,
            baseSHA: baseSHA
        )
    }

    private func makeProject(fixture: Fixture) -> CodingProject {
        CodingProject(
            name: "fixture",
            repositoryPath: fixture.repositoryURL.path,
            gitIdentity: "workspace-tests"
        )
    }

    private func makeTask(projectID: UUID) -> CodingTask {
        CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "Fixture task",
            objective: "Exercise the managed workspace layer",
            status: .ready,
            createdAt: startDate,
            updatedAt: startDate
        )
    }

    private func makeAttempt(taskID: UUID) -> TaskAttempt {
        TaskAttempt(
            taskID: taskID,
            attemptSequence: 1,
            role: .developer,
            providerID: "fixture-runtime",
            modelID: "fixture-model",
            generation: 1,
            leaseOwner: "workspace-tests",
            leaseToken: UUID().uuidString,
            leaseExpiry: startDate.addingTimeInterval(600),
            startedAt: startDate
        )
    }

    private func makeApproval(taskID: UUID, attemptID: UUID) -> TaskApproval {
        TaskApproval(
            taskID: taskID,
            attemptID: attemptID,
            fingerprint: "fixture-fingerprint",
            actor: "workspace-tests",
            timestamp: startDate,
            action: .discardWorkspace
        )
    }

    private func makeManager(
        fixture: Fixture,
        projects: [CodingProject],
        events: (any WorkspaceEventRecording)?,
        authorizedProjectRoots: [URL]? = nil
    ) -> GitWorkspaceManager {
        GitWorkspaceManager(
            runner: GitCommandRunner(
                executableDirectory: URL(fileURLWithPath: "/usr/bin"),
                maxOutputBytes: 262_144
            ),
            projects: StaticProjectResolver(projects: projects),
            events: events,
            configuration: WorkspaceManagerConfiguration(
                authorizedRoot: fixture.authorizedRoot,
                authorizedProjectRoots: authorizedProjectRoots ?? [fixture.projectsRoot]
            )
        )
    }

    private func workspaceTarget(fixture: Fixture, projectID: UUID, taskID: UUID, workspaceID: UUID) -> URL {
        fixture.authorizedRoot.appendingPathComponent(
            "worktrees/\(projectID.uuidString)/\(taskID.uuidString)/\(workspaceID.uuidString)",
            isDirectory: true
        )
    }

    private func manifestFile(fixture: Fixture, projectID: UUID, taskID: UUID, workspaceID: UUID) -> URL {
        fixture.authorizedRoot.appendingPathComponent(
            "registry/\(projectID.uuidString)/\(taskID.uuidString)/\(workspaceID.uuidString).json",
            isDirectory: false
        )
    }

    private func writeManifest(_ manifest: WorkspaceManifest, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest.encoded().write(to: url, options: [.atomic])
    }

    private func commonDirIdentity(of repositoryURL: URL) throws -> String {
        let result = try runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repositoryURL)
        return canonical(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func guardError(from preflight: WorkspacePreflight) -> WorkspaceGuardError? {
        guard case .blocked(let error) = preflight else { return nil }
        return error
    }

    private func assertGuardError(
        _ preflight: WorkspacePreflight,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let error = guardError(from: preflight) else {
            XCTFail("expected blocked \(code), got \(preflight)", file: file, line: line)
            return
        }
        XCTAssertEqual(error.code, code, file: file, line: line)
    }

    private func assertThrownGuardError(
        _ body: () async throws -> Void,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(code) refusal", file: file, line: line)
        } catch let error as WorkspaceGuardError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Preflight guards

    func testPreflightRefusesDirtyTrackedRoot() async throws {
        let fixture = try makeCleanFixture(name: "dirty-tracked")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let readme = fixture.repositoryURL.appendingPathComponent("README.md")
        try Data("tracked\nmodified\n".utf8).write(to: readme)

        assertGuardError(await manager.preflight(project: project, task: task), code: "WORKTREE_DIRTY")
    }

    func testPreflightRefusesDirtyUntrackedRoot() async throws {
        let fixture = try makeCleanFixture(name: "dirty-untracked")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        try Data("scratch\n".utf8).write(to: fixture.repositoryURL.appendingPathComponent("notes.txt"))

        assertGuardError(await manager.preflight(project: project, task: task), code: "WORKTREE_DIRTY")
    }

    func testPreflightRefusesProtectedBranch() async throws {
        let fixture = try makeCleanFixture(name: "protected-branch")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        try runGit(["switch", "main"], in: fixture.repositoryURL)

        assertGuardError(await manager.preflight(project: project, task: task), code: "WORKTREE_PROTECTED_BRANCH")
    }

    func testPreflightRefusesSymlinkEscapeInWorkspaceTarget() async throws {
        let fixture = try makeCleanFixture(name: "symlink-escape")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let taskDirectory = fixture.authorizedRoot.appendingPathComponent(
            "worktrees/\(project.id.uuidString)/\(task.id.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: taskDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: taskDirectory, withDestinationURL: outside)

        let preflight = await manager.preflight(project: project, task: task)
        guard case .blocked(.symlinkEscape(let path)) = preflight else {
            XCTFail("expected symlink escape refusal, got \(preflight)")
            return
        }
        XCTAssertEqual(path, canonical(taskDirectory))
    }

    func testPreflightRefusesProjectOutsideAuthorizedScope() async throws {
        let fixture = try makeCleanFixture(name: "scope")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let otherRoot = fixture.root.appendingPathComponent("other-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil, authorizedProjectRoots: [otherRoot])

        let preflight = await manager.preflight(project: project, task: task)
        guard case .blocked(.outsideAuthorizedScope(let path)) = preflight else {
            XCTFail("expected scope refusal, got \(preflight)")
            return
        }
        XCTAssertEqual(path, canonical(fixture.repositoryURL))
    }

    func testPreflightRefusesWhenWorkspaceRootLivesInsideRepository() async throws {
        let fixture = try makeCleanFixture(name: "root-inside-repo")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let nestedRoot = fixture.repositoryURL.appendingPathComponent(".managed", isDirectory: true)
        let manager = GitWorkspaceManager(
            runner: GitCommandRunner(
                executableDirectory: URL(fileURLWithPath: "/usr/bin"),
                maxOutputBytes: 262_144
            ),
            projects: StaticProjectResolver(projects: [project]),
            events: nil,
            configuration: WorkspaceManagerConfiguration(
                authorizedRoot: nestedRoot,
                authorizedProjectRoots: [fixture.projectsRoot]
            )
        )

        assertGuardError(await manager.preflight(project: project, task: task), code: "WORKTREE_ROOT_INSIDE_REPOSITORY")
    }

    func testPreflightRefusesFakeForeignManifest() async throws {
        let fixture = try makeCleanFixture(name: "foreign-manifest")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let workspaceID = UUID()
        let foreignRecord = WorkspaceRecord(
            workspaceID: workspaceID,
            projectID: project.id,
            taskID: UUID(),
            attemptID: UUID(),
            repositoryPath: fixture.repositoryURL.path,
            workspacePath: workspaceTarget(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: workspaceID).path,
            commonDirIdentity: try commonDirIdentity(of: fixture.repositoryURL),
            baseSHA: fixture.baseSHA,
            nonce: UUID().uuidString,
            createdAt: startDate
        )
        try writeManifest(
            WorkspaceManifest(record: foreignRecord),
            to: manifestFile(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: workspaceID)
        )

        assertGuardError(await manager.preflight(project: project, task: task), code: "WORKTREE_FOREIGN_MANIFEST")
    }

    func testPreflightRefusesManifestWithWorkspacePathOutsideAuthorizedRoot() async throws {
        let fixture = try makeCleanFixture(name: "manifest-outside")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let workspaceID = UUID()
        let outsidePath = fixture.root.appendingPathComponent("elsewhere/\(workspaceID.uuidString)").path
        let escapedRecord = WorkspaceRecord(
            workspaceID: workspaceID,
            projectID: project.id,
            taskID: task.id,
            attemptID: UUID(),
            repositoryPath: fixture.repositoryURL.path,
            workspacePath: outsidePath,
            commonDirIdentity: try commonDirIdentity(of: fixture.repositoryURL),
            baseSHA: fixture.baseSHA,
            nonce: UUID().uuidString,
            createdAt: startDate
        )
        try writeManifest(
            WorkspaceManifest(record: escapedRecord),
            to: manifestFile(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: workspaceID)
        )

        assertGuardError(await manager.preflight(project: project, task: task), code: "WORKTREE_FOREIGN_MANIFEST")
    }

    func testPreflightRefusesMismatchedGitCommonDir() async throws {
        let fixture = try makeCleanFixture(name: "common-dir")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let workspaceID = UUID()
        let record = WorkspaceRecord(
            workspaceID: workspaceID,
            projectID: project.id,
            taskID: task.id,
            attemptID: UUID(),
            repositoryPath: fixture.repositoryURL.path,
            workspacePath: workspaceTarget(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: workspaceID).path,
            commonDirIdentity: "/nonexistent/foreign.git",
            baseSHA: fixture.baseSHA,
            nonce: UUID().uuidString,
            createdAt: startDate
        )
        try writeManifest(
            WorkspaceManifest(record: record),
            to: manifestFile(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: workspaceID)
        )

        let preflight = await manager.preflight(project: project, task: task)
        guard case .blocked(.commonDirMismatch(let expected, let actual)) = preflight else {
            XCTFail("expected common dir mismatch, got \(preflight)")
            return
        }
        XCTAssertEqual(expected, "/nonexistent/foreign.git")
        XCTAssertEqual(actual, try commonDirIdentity(of: fixture.repositoryURL))
    }

    // MARK: - Creation and provenance

    func testCreateOwnedWorkspaceKeepsSourceBranchHashAndIgnoredFilesUnchanged() async throws {
        let fixture = try makeCleanFixture(name: "create")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let events = RecordingWorkspaceEvents(failure: nil)
        let manager = makeManager(fixture: fixture, projects: [project], events: events)

        let ignoredArtifact = fixture.repositoryURL.appendingPathComponent(".build/artifact.bin")
        let ignoredBefore = try Data(contentsOf: ignoredArtifact)
        let branchBefore = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: fixture.repositoryURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headBefore = try runGit(["rev-parse", "HEAD"], in: fixture.repositoryURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .notOwned = await manager.preflight(project: project, task: task) else {
            XCTFail("expected notOwned before creation")
            return
        }

        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )

        XCTAssertEqual(record.projectID, project.id)
        XCTAssertEqual(record.taskID, task.id)
        XCTAssertEqual(record.attemptID, attempt.id)
        XCTAssertEqual(record.baseSHA, fixture.baseSHA)
        XCTAssertFalse(record.nonce.isEmpty)
        XCTAssertEqual(record.repositoryPath, canonical(fixture.repositoryURL))
        XCTAssertEqual(
            record.workspacePath,
            canonical(workspaceTarget(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: record.workspaceID))
        )

        let workspaceURL = URL(fileURLWithPath: record.workspacePath)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let worktreeHead = try runGit(["rev-parse", "HEAD"], in: workspaceURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(worktreeHead, fixture.baseSHA)

        let manifest = try WorkspaceManifest.decode(
            from: Data(
                contentsOf: manifestFile(
                    fixture: fixture,
                    projectID: project.id,
                    taskID: task.id,
                    workspaceID: record.workspaceID
                ))
        )
        XCTAssertEqual(manifest, WorkspaceManifest(record: record))
        XCTAssertEqual(manifest.commonDirIdentity, try commonDirIdentity(of: fixture.repositoryURL))

        let branchAfter = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: fixture.repositoryURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headAfter = try runGit(["rev-parse", "HEAD"], in: fixture.repositoryURL)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branchAfter, branchBefore)
        XCTAssertEqual(headAfter, headBefore)
        XCTAssertEqual(try Data(contentsOf: ignoredArtifact), ignoredBefore)
        let sourceStatus = try runGit(["status", "--porcelain=v1", "--untracked-files=all"], in: fixture.repositoryURL).stdout
        XCTAssertTrue(sourceStatus.isEmpty, "source repository became dirty: \(sourceStatus)")

        XCTAssertEqual(events.events.count, 1)
        let event = try XCTUnwrap(events.events.first)
        XCTAssertEqual(event.taskID, task.id)
        XCTAssertEqual(event.attemptID, attempt.id)
        XCTAssertEqual(event.kind, "workspace.created")
        XCTAssertTrue(event.redactedPayload.contains(record.workspaceID.uuidString))

        let preflight = await manager.preflight(project: project, task: task)
        guard case .owned(let ownedRecord, let holder) = preflight else {
            XCTFail("expected owned workspace after creation, got \(preflight)")
            return
        }
        XCTAssertEqual(ownedRecord, record)
        XCTAssertEqual(holder, .active(attemptID: attempt.id))

        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)
        let idlePreflight = await manager.preflight(project: project, task: task)
        guard case .owned(_, let idleHolder) = idlePreflight else {
            XCTFail("expected idle owned workspace, got \(idlePreflight)")
            return
        }
        XCTAssertEqual(idleHolder, .idle)
    }

    func testFreshManagerTreatsPersistedWorkspaceAsIdle() async throws {
        let fixture = try makeCleanFixture(name: "fresh-manager")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let creator = makeManager(fixture: fixture, projects: [project], events: nil)
        _ = try await creator.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )

        let fresh = makeManager(fixture: fixture, projects: [project], events: nil)
        let preflight = await fresh.preflight(project: project, task: task)
        guard case .owned(let record, let holder) = preflight else {
            XCTFail("expected owned workspace for fresh process, got \(preflight)")
            return
        }
        XCTAssertEqual(holder, .idle)
        XCTAssertEqual(record.taskID, task.id)
    }

    func testCreateRefusesWhenOwnedWorkspaceAlreadyExists() async throws {
        let fixture = try makeCleanFixture(name: "already-owned")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )

        await assertThrownGuardError(
            {
                _ = try await manager.createOwnedWorkspace(
                    task: task,
                    attempt: makeAttempt(taskID: task.id),
                    base: WorkspaceBase(commitSHA: fixture.baseSHA)
                )
            },
            code: "WORKTREE_ALREADY_OWNED"
        )

        let preflight = await manager.preflight(project: project, task: task)
        guard case .owned(let ownedRecord, _) = preflight else {
            XCTFail("existing workspace must stay owned, got \(preflight)")
            return
        }
        XCTAssertEqual(ownedRecord.workspaceID, record.workspaceID)
    }

    func testCreateRefusesDirtySourceBeforeAnyMutation() async throws {
        let fixture = try makeCleanFixture(name: "create-dirty")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        try Data("dirty\n".utf8).write(to: fixture.repositoryURL.appendingPathComponent("dirty.txt"))

        await assertThrownGuardError(
            {
                _ = try await manager.createOwnedWorkspace(
                    task: task,
                    attempt: makeAttempt(taskID: task.id),
                    base: WorkspaceBase(commitSHA: fixture.baseSHA)
                )
            },
            code: "WORKTREE_DIRTY"
        )

        let worktreesRoot = fixture.authorizedRoot.appendingPathComponent("worktrees", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreesRoot.path))
        let registryRoot = fixture.authorizedRoot.appendingPathComponent("registry", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
    }

    func testCreateRefusesInvalidAndMissingBase() async throws {
        let fixture = try makeCleanFixture(name: "invalid-base")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        await assertThrownGuardError(
            {
                _ = try await manager.createOwnedWorkspace(
                    task: task,
                    attempt: makeAttempt(taskID: task.id),
                    base: WorkspaceBase(commitSHA: "--help")
                )
            },
            code: "WORKTREE_INVALID_BASE"
        )

        await assertThrownGuardError(
            {
                _ = try await manager.createOwnedWorkspace(
                    task: task,
                    attempt: makeAttempt(taskID: task.id),
                    base: WorkspaceBase(commitSHA: String(repeating: "a", count: 40))
                )
            },
            code: "WORKTREE_BASE_NOT_FOUND"
        )
    }

    func testCreateRollsBackWorktreeWhenStoreRecordFails() async throws {
        let fixture = try makeCleanFixture(name: "store-failure")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let events = RecordingWorkspaceEvents(failure: SpyFailure.storeUnavailable)
        let manager = makeManager(fixture: fixture, projects: [project], events: events)

        await assertThrownGuardError(
            {
                _ = try await manager.createOwnedWorkspace(
                    task: task,
                    attempt: makeAttempt(taskID: task.id),
                    base: WorkspaceBase(commitSHA: fixture.baseSHA)
                )
            },
            code: "WORKTREE_STORE_RECORD_FAILED"
        )

        let worktreesRoot = fixture.authorizedRoot.appendingPathComponent("worktrees", isDirectory: true)
        if FileManager.default.fileExists(atPath: worktreesRoot.path) {
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: worktreesRoot.path)
            XCTAssertTrue(leftovers.isEmpty, "worktree leftovers after rollback: \(leftovers)")
        }
        let registryRoot = fixture.authorizedRoot.appendingPathComponent("registry", isDirectory: true)
        if FileManager.default.fileExists(atPath: registryRoot.path) {
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: registryRoot.path)
            XCTAssertTrue(leftovers.isEmpty, "manifest leftovers after rollback: \(leftovers)")
        }
        let worktreeList = try runGit(["worktree", "list", "--porcelain"], in: fixture.repositoryURL).stdout
        XCTAssertFalse(worktreeList.contains(task.id.uuidString), "rollback left a registered worktree")
    }

    // MARK: - Inspection

    func testInspectReportsCleanDirtyAndUnknownWorkspaces() async throws {
        let fixture = try makeCleanFixture(name: "inspect")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )

        guard case .present(let cleanReport) = await manager.inspect(workspaceID: record.workspaceID) else {
            XCTFail("expected present inspection")
            return
        }
        XCTAssertEqual(cleanReport.record, record)
        XCTAssertEqual(cleanReport.holder, .active(attemptID: attempt.id))
        XCTAssertEqual(cleanReport.cleanliness, .clean)

        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)
        guard case .present(let idleReport) = await manager.inspect(workspaceID: record.workspaceID) else {
            XCTFail("expected idle inspection")
            return
        }
        XCTAssertEqual(idleReport.holder, .idle)

        try Data("dirty\n".utf8).write(to: URL(fileURLWithPath: record.workspacePath).appendingPathComponent("dirty.txt"))
        guard case .present(let dirtyReport) = await manager.inspect(workspaceID: record.workspaceID) else {
            XCTFail("expected dirty inspection")
            return
        }
        guard case .dirty = dirtyReport.cleanliness else {
            XCTFail("expected dirty cleanliness, got \(dirtyReport.cleanliness)")
            return
        }

        let unknown = UUID()
        let unknownInspection = await manager.inspect(workspaceID: unknown)
        XCTAssertEqual(unknownInspection, .unknown(workspaceID: unknown))
    }

    // MARK: - Retirement

    func testRetireRemovesCleanOwnedWorktreeAndManifest() async throws {
        let fixture = try makeCleanFixture(name: "retire")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)

        try await manager.retire(workspaceID: record.workspaceID, approval: makeApproval(taskID: task.id, attemptID: attempt.id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: record.workspacePath))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: manifestFile(
                    fixture: fixture,
                    projectID: project.id,
                    taskID: task.id,
                    workspaceID: record.workspaceID
                ).path
            )
        )
        let worktreeList = try runGit(["worktree", "list", "--porcelain"], in: fixture.repositoryURL).stdout
        XCTAssertFalse(worktreeList.contains("\(record.workspacePath)\n"), "worktree stayed registered: \(worktreeList)")

        let preflight = await manager.preflight(project: project, task: task)
        guard case .notOwned = preflight else {
            XCTFail("expected notOwned after retirement, got \(preflight)")
            return
        }
        let retiredInspection = await manager.inspect(workspaceID: record.workspaceID)
        XCTAssertEqual(retiredInspection, .unknown(workspaceID: record.workspaceID))
    }

    func testRetireRefusesDirtyOwnedWorkspaceAndReportsManualPath() async throws {
        let fixture = try makeCleanFixture(name: "retire-dirty")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)
        try Data("work in progress\n".utf8).write(
            to: URL(fileURLWithPath: record.workspacePath).appendingPathComponent("wip.txt")
        )

        do {
            try await manager.retire(
                workspaceID: record.workspaceID,
                approval: makeApproval(taskID: task.id, attemptID: attempt.id)
            )
            XCTFail("expected dirty retirement refusal")
        } catch let error as WorkspaceGuardError {
            guard case .dirtyOwnedWorkspace(let workspaceID, let manualInspectionPath) = error else {
                XCTFail("unexpected guard error \(error)")
                return
            }
            XCTAssertEqual(workspaceID, record.workspaceID)
            XCTAssertEqual(manualInspectionPath, record.workspacePath)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: record.workspacePath))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: manifestFile(
                    fixture: fixture,
                    projectID: project.id,
                    taskID: task.id,
                    workspaceID: record.workspaceID
                ).path
            )
        )
    }

    func testRetireRefusesUnknownWorkspace() async throws {
        let fixture = try makeCleanFixture(name: "retire-unknown")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        await assertThrownGuardError(
            {
                try await manager.retire(
                    workspaceID: UUID(),
                    approval: makeApproval(taskID: task.id, attemptID: UUID())
                )
            },
            code: "WORKTREE_UNKNOWN"
        )
    }

    func testRetireRefusesActiveWorkspace() async throws {
        let fixture = try makeCleanFixture(name: "retire-active")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )

        await assertThrownGuardError(
            {
                try await manager.retire(
                    workspaceID: record.workspaceID,
                    approval: makeApproval(taskID: task.id, attemptID: attempt.id)
                )
            },
            code: "WORKTREE_ACTIVE"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.workspacePath))
    }

    func testRetireRefusesForeignManifestWithoutDeletingAnything() async throws {
        let fixture = try makeCleanFixture(name: "retire-foreign")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let otherTask = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)

        let workspaceID = UUID()
        let target = workspaceTarget(fixture: fixture, projectID: project.id, taskID: otherTask.id, workspaceID: workspaceID)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let forgedRecord = WorkspaceRecord(
            workspaceID: workspaceID,
            projectID: project.id,
            taskID: otherTask.id,
            attemptID: UUID(),
            repositoryPath: fixture.repositoryURL.path,
            workspacePath: target.path,
            commonDirIdentity: try commonDirIdentity(of: fixture.repositoryURL),
            baseSHA: fixture.baseSHA,
            nonce: UUID().uuidString,
            createdAt: startDate
        )
        // Manifest content says otherTask, but the file lives under task's registry: dishonest provenance.
        try writeManifest(
            WorkspaceManifest(record: forgedRecord),
            to: manifestFile(fixture: fixture, projectID: project.id, taskID: task.id, workspaceID: workspaceID)
        )

        await assertThrownGuardError(
            {
                try await manager.retire(
                    workspaceID: workspaceID,
                    approval: makeApproval(taskID: otherTask.id, attemptID: forgedRecord.attemptID)
                )
            },
            code: "WORKTREE_FOREIGN_MANIFEST"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRetireRefusesApprovalForAnotherTaskOrAction() async throws {
        let fixture = try makeCleanFixture(name: "retire-approval")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)

        let wrongAction = TaskApproval(
            taskID: task.id,
            attemptID: attempt.id,
            fingerprint: "fixture-fingerprint",
            actor: "workspace-tests",
            timestamp: startDate,
            action: .accept
        )
        await assertThrownGuardError(
            {
                try await manager.retire(workspaceID: record.workspaceID, approval: wrongAction)
            },
            code: "WORKTREE_APPROVAL_REJECTED"
        )

        let wrongTask = makeApproval(taskID: UUID(), attemptID: attempt.id)
        await assertThrownGuardError(
            {
                try await manager.retire(workspaceID: record.workspaceID, approval: wrongTask)
            },
            code: "WORKTREE_APPROVAL_REJECTED"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.workspacePath))
    }

    // MARK: - Port adapters

    func testSchedulerAdapterMapsOwnedWorkspaceToDescriptorAndDefersOtherwise() async throws {
        let fixture = try makeCleanFixture(name: "scheduler-adapter")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let adapter = GitWorkspaceSchedulerAdapter(
            manager: manager,
            projects: StaticProjectResolver(projects: [project]),
            tasks: StaticTaskResolver(tasks: [task])
        )

        guard case .notOwned = await adapter.preflight(projectID: project.id, taskID: task.id) else {
            XCTFail("expected notOwned before creation")
            return
        }

        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)

        let result = await adapter.preflight(projectID: project.id, taskID: task.id)
        guard case .owned(let descriptor) = result else {
            XCTFail("expected owned descriptor, got \(result)")
            return
        }
        XCTAssertEqual(descriptor.workspaceID, record.workspaceID)
        XCTAssertEqual(descriptor.workspacePath, record.workspacePath)
        XCTAssertEqual(descriptor.repositoryPath, record.repositoryPath)

        let unknownProjectResult = await adapter.preflight(projectID: UUID(), taskID: task.id)
        guard case .unavailable = unknownProjectResult else {
            XCTFail("unknown project must be unavailable, got \(unknownProjectResult)")
            return
        }
    }

    func testRecoveryAdapterMapsIdleWorkspaceToNotActivelyOwned() async throws {
        let fixture = try makeCleanFixture(name: "recovery-idle")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)
        let adapter = GitWorkspaceRecoveryAdapter(manager: manager)
        let danglingAttempt = TaskAttempt(
            id: attempt.id,
            taskID: task.id,
            attemptSequence: 1,
            role: .developer,
            providerID: "fixture-runtime",
            modelID: "fixture-model",
            workspaceID: record.workspaceID,
            generation: 1,
            startedAt: startDate
        )

        let status = await adapter.workspaceStatus(for: danglingAttempt)
        XCTAssertEqual(status, .notActivelyOwned(repositoryPath: record.repositoryPath))
    }

    func testRecoveryAdapterMapsActiveWorkspaceToActivelyOwned() async throws {
        let fixture = try makeCleanFixture(name: "recovery-active")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        let adapter = GitWorkspaceRecoveryAdapter(manager: manager)
        let liveAttempt = TaskAttempt(
            id: attempt.id,
            taskID: task.id,
            attemptSequence: 1,
            role: .developer,
            providerID: "fixture-runtime",
            modelID: "fixture-model",
            workspaceID: record.workspaceID,
            generation: 1,
            startedAt: startDate
        )

        let status = await adapter.workspaceStatus(for: liveAttempt)
        XCTAssertEqual(
            status,
            .activelyOwned(
                TaskWorkspaceDescriptor(
                    workspaceID: record.workspaceID,
                    workspacePath: record.workspacePath,
                    repositoryPath: record.repositoryPath
                )
            )
        )

        let otherGeneration = TaskAttempt(
            id: UUID(),
            taskID: task.id,
            attemptSequence: 2,
            role: .developer,
            providerID: "fixture-runtime",
            modelID: "fixture-model",
            workspaceID: record.workspaceID,
            generation: 2,
            startedAt: startDate
        )
        guard case .unknown = await adapter.workspaceStatus(for: otherGeneration) else {
            XCTFail("a workspace held by another attempt must stay unknown")
            return
        }
    }

    func testRecoveryAdapterReportsUnknownForMissingWorkspaceIdentity() async throws {
        let fixture = try makeCleanFixture(name: "recovery-unknown")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let adapter = GitWorkspaceRecoveryAdapter(manager: manager)
        let noWorkspaceAttempt = makeAttempt(taskID: task.id)

        guard case .unknown = await adapter.workspaceStatus(for: noWorkspaceAttempt) else {
            XCTFail("an attempt without workspace identity must stay unknown")
            return
        }

        let missingWorkspaceAttempt = TaskAttempt(
            id: UUID(),
            taskID: task.id,
            attemptSequence: 1,
            role: .developer,
            providerID: "fixture-runtime",
            modelID: "fixture-model",
            workspaceID: UUID(),
            generation: 1,
            startedAt: startDate
        )
        guard case .unknown = await adapter.workspaceStatus(for: missingWorkspaceAttempt) else {
            XCTFail("a missing workspace record must stay unknown")
            return
        }
    }

    // MARK: - Command runner

    func testGitCommandRunnerRunsFixedArgvAndCapturesExitCodeStdoutStderr() async throws {
        let fixture = try makeCleanFixture(name: "runner")
        let runner = GitCommandRunner(
            executableDirectory: URL(fileURLWithPath: "/usr/bin"),
            maxOutputBytes: 262_144
        )

        let success = try runner.run(
            executable: "git",
            arguments: ["rev-parse", "--is-inside-work-tree"],
            directory: fixture.repositoryURL
        )
        XCTAssertEqual(success.exitCode, 0)
        XCTAssertEqual(success.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "true")
        XCTAssertFalse(success.outputWasTruncated)

        let failure = try runner.run(
            executable: "git",
            arguments: ["rev-parse", "--verify", "definitely-not-a-ref"],
            directory: fixture.repositoryURL
        )
        XCTAssertNotEqual(failure.exitCode, 0)
        XCTAssertFalse(failure.standardError.isEmpty)
    }

    func testGitCommandRunnerRejectsExecutableNamesWithPathSeparators() async throws {
        let fixture = try makeCleanFixture(name: "runner-reject")
        let runner = GitCommandRunner(
            executableDirectory: URL(fileURLWithPath: "/usr/bin"),
            maxOutputBytes: 262_144
        )

        for name in ["../bin/git", "git;rm", "git rm", ""] {
            do {
                _ = try runner.run(executable: name, arguments: [], directory: fixture.repositoryURL)
                XCTFail("expected refusal for executable name \(name)")
            } catch let error as GitCommandRunnerError {
                guard case .invalidExecutableName = error else {
                    XCTFail("unexpected runner error \(error) for \(name)")
                    return
                }
            }
        }
    }

    func testGitCommandRunnerBoundsLargeOutput() async throws {
        let fixture = try makeCleanFixture(name: "runner-bounded")
        let runner = GitCommandRunner(
            executableDirectory: URL(fileURLWithPath: "/usr/bin"),
            maxOutputBytes: 4_096
        )

        let result = try runner.run(
            executable: "seq",
            arguments: ["1", "200000"],
            directory: fixture.repositoryURL
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 4_096)
    }

    // MARK: - Real-host smoke

    func testRealHostManagedWorktreeSmokeLeavesNoOrphans() async throws {
        let fixture = try makeCleanFixture(name: "real-host-smoke")
        let project = makeProject(fixture: fixture)
        let task = makeTask(projectID: project.id)
        let attempt = makeAttempt(taskID: task.id)
        let manager = makeManager(fixture: fixture, projects: [project], events: nil)
        let ignoredArtifact = fixture.repositoryURL.appendingPathComponent(".build/artifact.bin")
        let ignoredBefore = try Data(contentsOf: ignoredArtifact)
        let branchBefore = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: fixture.repositoryURL).stdout
        let headBefore = try runGit(["rev-parse", "HEAD"], in: fixture.repositoryURL).stdout

        let record = try await manager.createOwnedWorkspace(
            task: task,
            attempt: attempt,
            base: WorkspaceBase(commitSHA: fixture.baseSHA)
        )
        let workspaceURL = URL(fileURLWithPath: record.workspacePath)

        let pwd = try runTool("/bin/pwd", [], in: workspaceURL)
        XCTAssertEqual(pwd.exitCode, 0)
        XCTAssertEqual(canonical(URL(fileURLWithPath: pwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines))), record.workspacePath)

        let registration = try runGit(["worktree", "list", "--porcelain"], in: fixture.repositoryURL).stdout
        XCTAssertTrue(
            registration.split(separator: "\n").contains { line in
                line.hasPrefix("worktree ")
                    && canonical(URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))) == record.workspacePath
            },
            "managed worktree is not registered: record=\(record.workspacePath) list=\(registration)"
        )

        await manager.releaseOwnedWorkspace(workspaceID: record.workspaceID, attemptID: attempt.id)
        try await manager.retire(workspaceID: record.workspaceID, approval: makeApproval(taskID: task.id, attemptID: attempt.id))

        XCTAssertEqual(try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: fixture.repositoryURL).stdout, branchBefore)
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: fixture.repositoryURL).stdout, headBefore)
        XCTAssertEqual(try Data(contentsOf: ignoredArtifact), ignoredBefore)
        XCTAssertTrue(
            try runGit(["status", "--porcelain=v1", "--untracked-files=all"], in: fixture.repositoryURL).stdout.isEmpty
        )

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], in: fixture.repositoryURL).stdout
        XCTAssertFalse(worktreeList.contains(record.workspacePath), "orphaned worktree registration: \(worktreeList)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.workspacePath), "orphaned worktree directory")

        let strayProcesses = try runTool("pgrep", ["-f", record.workspacePath], in: fixture.root)
        XCTAssertEqual(strayProcesses.exitCode, 1, "orphaned child process: \(strayProcesses.stdout)")
    }
}

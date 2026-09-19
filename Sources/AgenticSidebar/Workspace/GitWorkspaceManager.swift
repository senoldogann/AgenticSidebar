import Foundation

/// Configuration for the managed workspace layer.
///
/// `authorizedRoot` is the dedicated, user-authorized application-owned directory
/// where registries and worktrees live; it may never sit inside a source repository.
/// `authorizedProjectRoots` narrows which repositories may be managed at all; an
/// empty list treats the registered project path itself as its own authorization.
struct WorkspaceManagerConfiguration: Sendable, Equatable {
    let authorizedRoot: URL
    let authorizedProjectRoots: [URL]
}

/// Git worktree implementation of the managed workspace port.
///
/// Layout (all inside the app-owned `authorizedRoot`):
/// - `registry/<projectID>/<taskID>/<workspaceID>.json` — atomic provenance manifests
/// - `worktrees/<projectID>/<taskID>/<workspaceID>` — detached Git worktrees
///
/// Creation and retirement are the only mutating operations, and both run only after
/// the official authority preflight passes. The source checkout is never touched:
/// `git worktree add --detach <path> <sha>` leaves the source branch and HEAD exactly
/// where they were, and no destructive Git command is ever issued.
actor GitWorkspaceManager: WorkspaceManaging {
    private struct WorkspaceHolding: Sendable, Equatable {
        let workspaceID: UUID
        let taskID: UUID
        let attemptID: UUID
        let nonce: String
    }

    private static let maxStatusCharacters = 1_000
    private static let commitObjectNamePattern = "^(?:[0-9a-f]{40}|[0-9a-f]{64})$"

    private let runner: GitCommandRunner
    private let projects: any WorkspaceProjectResolving
    private let events: (any WorkspaceEventRecording)?
    private let configuration: WorkspaceManagerConfiguration

    /// Live holders registered by this process; a fresh process starts empty, which
    /// is what makes persisted workspaces idle for recovery after a relaunch.
    private var holdings: [UUID: WorkspaceHolding] = [:]

    init(
        runner: GitCommandRunner,
        projects: any WorkspaceProjectResolving,
        events: (any WorkspaceEventRecording)?,
        configuration: WorkspaceManagerConfiguration
    ) {
        self.runner = runner
        self.projects = projects
        self.events = events
        self.configuration = configuration
    }

    // MARK: - WorkspaceManaging

    func preflight(project: CodingProject, task: CodingTask) async -> WorkspacePreflight {
        do {
            try validateProjectIdentity(project: project, task: task)
            try assertWorkspaceRootOutsideRepository(project: project)
            try assertTargetIsSafe(projectID: task.projectID, taskID: task.id, workspaceID: nil)
            // Ownership is decided from the manifest and Git registration before source
            // cleanliness: a dirty source checkout must never mask a valid owned workspace
            // (that would surface as WORKTREE_DIRTY and hide the workspace from recovery).
            let manifests = try publishableManifests(projectID: project.id, taskID: task.id)
            guard manifests.count <= 1 else {
                throw WorkspaceGuardError.foreignManifest(
                    workspaceID: nil,
                    reason: "task \(task.id.uuidString) has \(manifests.count) manifests"
                )
            }
            guard let manifestURL = manifests.first else {
                // No owned workspace exists: this is the creation path, so the source
                // must be clean and the branch writable before anything may be created.
                try verifySourceIsClean(project: project)
                try verifyBranchIsWritable(project: project)
                return .notOwned(reason: "no owned workspace for task \(task.id.uuidString)")
            }
            // A preflight may only offer a workspace whose manifest and Git registration
            // both exist: metadata alone could describe a phantom worktree.
            let record = try validatedRecord(
                at: manifestURL,
                expectedWorkspaceID: nil,
                expectedProject: project,
                expectedTaskID: task.id
            )
            guard FileManager.default.fileExists(atPath: record.workspacePath) else {
                throw WorkspaceGuardError.foreignManifest(
                    workspaceID: record.workspaceID,
                    reason: "workspace directory is missing at \(record.workspacePath)"
                )
            }
            try verifyWorktreeRegistration(record: record, repositoryURL: URL(fileURLWithPath: record.repositoryPath))
            return .owned(record, holder: holder(for: record))
        } catch let error as WorkspaceGuardError {
            return .blocked(error)
        } catch {
            return .unavailable(reason: "workspace preflight failed: \(error)")
        }
    }

    func createOwnedWorkspace(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord {
        guard let project = await projects.resolveProject(id: task.projectID) else {
            throw WorkspaceGuardError.projectNotFound(projectID: task.projectID)
        }
        guard attempt.taskID == task.id else {
            throw WorkspaceGuardError.attemptTaskMismatch(taskID: task.id, attemptID: attempt.id)
        }

        // Creation only happens after the official authority preflight passes.
        switch await preflight(project: project, task: task) {
        case .owned(let record, _):
            throw WorkspaceGuardError.workspaceAlreadyOwned(workspaceID: record.workspaceID)
        case .blocked(let error):
            throw error
        case .unavailable(let reason):
            throw WorkspaceGuardError.inspectionUnavailable(reason: reason)
        case .notOwned:
            break
        }

        let commitSHA = try normalizedCommitSHA(base.commitSHA)
        let repositoryURL = URL(fileURLWithPath: project.repositoryPath)
        try verifyCommitExists(commitSHA, repositoryURL: repositoryURL)
        let commonDirIdentity = try repositoryCommonDirIdentity(repositoryURL)
        try assertWorkspaceRootOutsideRepository(project: project)

        let workspaceID = UUID()
        let target = workspaceURL(projectID: project.id, taskID: task.id, workspaceID: workspaceID)
        try assertTargetIsSafe(projectID: project.id, taskID: task.id, workspaceID: workspaceID)
        let targetPath = canonicalPath(target)
        guard !FileManager.default.fileExists(atPath: targetPath) else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: workspaceID,
                reason: "workspace target already exists at \(targetPath)"
            )
        }

        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // No git process runs on this path, so this must not masquerade as a git exit.
            throw WorkspaceGuardError.storeRecordFailed(
                reason: "could not create workspace parent directory \(target.deletingLastPathComponent().path): \(error)"
            )
        }

        do {
            _ = try runGit(["worktree", "add", "--detach", targetPath, commitSHA], in: repositoryURL)
        } catch {
            removeEmptyDirectories(upTo: worktreesRoot, from: target.deletingLastPathComponent())
            throw error
        }

        let record = WorkspaceRecord(
            workspaceID: workspaceID,
            projectID: project.id,
            taskID: task.id,
            attemptID: attempt.id,
            repositoryPath: canonicalPath(repositoryURL),
            workspacePath: targetPath,
            commonDirIdentity: commonDirIdentity,
            baseSHA: commitSHA,
            nonce: UUID().uuidString,
            createdAt: Date()
        )
        let manifest = WorkspaceManifest(record: record)
        let manifestURL = manifestURL(projectID: project.id, taskID: task.id, workspaceID: workspaceID)

        do {
            let workspaceCommonDir = try repositoryCommonDirIdentity(URL(fileURLWithPath: targetPath))
            guard workspaceCommonDir == commonDirIdentity else {
                throw WorkspaceGuardError.commonDirMismatch(expected: commonDirIdentity, actual: workspaceCommonDir)
            }
            let head = try runGit(["rev-parse", "HEAD"], in: URL(fileURLWithPath: targetPath))
                .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == commitSHA else {
                throw WorkspaceGuardError.baseNotFound(sha: commitSHA)
            }
            try writeManifestAtomically(manifest, to: manifestURL)
            if let events {
                do {
                    try await events.recordWorkspaceEvent(makeEvent(manifest: manifest))
                } catch {
                    throw WorkspaceGuardError.storeRecordFailed(reason: "\(error)")
                }
            }
        } catch {
            rollbackWorktree(URL(fileURLWithPath: targetPath), manifestURL: manifestURL, repositoryURL: repositoryURL)
            throw error
        }

        holdings[workspaceID] = WorkspaceHolding(
            workspaceID: workspaceID,
            taskID: task.id,
            attemptID: attempt.id,
            nonce: record.nonce
        )
        return record
    }

    func inspect(workspaceID: UUID) async -> WorkspaceInspection {
        guard let manifestURL = findManifest(workspaceID: workspaceID) else {
            return .unknown(workspaceID: workspaceID)
        }
        do {
            let record = try validatedRecord(
                at: manifestURL,
                expectedWorkspaceID: workspaceID,
                expectedProject: nil,
                expectedTaskID: nil
            )
            return .present(
                WorkspaceInspectionReport(
                    record: record,
                    holder: holder(for: record),
                    cleanliness: workspaceCleanliness(record)
                )
            )
        } catch let error as WorkspaceGuardError {
            return .rejected(error)
        } catch {
            return .rejected(.foreignManifest(workspaceID: workspaceID, reason: "\(error)"))
        }
    }

    /// Retires one idle owned workspace after an explicit disposal approval.
    ///
    /// Approval binding: the action must be the retirement action (`.discardWorkspace`;
    /// `.accept` approvals belong to the acceptance path and never authorize disposal
    /// here), the fingerprint must be non-empty, and the approval must bind the exact
    /// task *and* attempt that created the workspace — a task-only match would let an
    /// approval issued for attempt A discard the workspace of attempt B.
    ///
    /// The full content-fingerprint comparison is deliberately not implemented here:
    /// it lives upstream in the AcceptanceGate (Task 12), which owns the reviewed
    /// content digest. This layer only refuses approvals that are structurally
    /// unbound to the workspace being disposed.
    ///
    /// A live holder is never implicitly released: retirement requires an explicit
    /// `releaseOwnedWorkspace` first, so an executing attempt cannot lose its workspace.
    func retire(workspaceID: UUID, approval: TaskApproval) async throws {
        guard approval.action == .discardWorkspace else {
            throw WorkspaceGuardError.approvalRejected(
                reason: "approval action \(approval.action.rawValue) does not authorize workspace disposal"
            )
        }
        guard !approval.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceGuardError.approvalRejected(reason: "approval fingerprint is empty")
        }
        guard let manifestURL = findManifest(workspaceID: workspaceID) else {
            throw WorkspaceGuardError.unknownWorkspace(workspaceID: workspaceID)
        }
        let record = try validatedRecord(
            at: manifestURL,
            expectedWorkspaceID: workspaceID,
            expectedProject: nil,
            expectedTaskID: nil
        )
        guard approval.taskID == record.taskID else {
            throw WorkspaceGuardError.approvalRejected(
                reason: "approval binds task \(approval.taskID.uuidString) but workspace belongs to task \(record.taskID.uuidString)"
            )
        }
        guard approval.attemptID == record.attemptID else {
            throw WorkspaceGuardError.approvalRejected(
                reason: "approval binds attempt \(approval.attemptID.uuidString) but workspace belongs to "
                    + "attempt \(record.attemptID.uuidString)"
            )
        }
        if let holding = holdings[workspaceID] {
            throw WorkspaceGuardError.activelyOwnedWorkspace(workspaceID: workspaceID, attemptID: holding.attemptID)
        }

        let workspaceURL = URL(fileURLWithPath: record.workspacePath)
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw WorkspaceGuardError.workspacePathMissing(workspaceID: workspaceID, path: record.workspacePath)
        }
        switch workspaceCleanliness(record) {
        case .clean:
            break
        case .dirty:
            throw WorkspaceGuardError.dirtyOwnedWorkspace(
                workspaceID: workspaceID,
                manualInspectionPath: record.workspacePath
            )
        case .unreadable(let reason):
            throw WorkspaceGuardError.cleanlinessUnreadable(reason: reason)
        }

        let repositoryURL = URL(fileURLWithPath: record.repositoryPath)
        // Root and common-dir identity are rechecked immediately before the mutation.
        let actualCommonDir = try repositoryCommonDirIdentity(repositoryURL)
        guard actualCommonDir == record.commonDirIdentity else {
            throw WorkspaceGuardError.commonDirMismatch(expected: record.commonDirIdentity, actual: actualCommonDir)
        }
        try verifyWorktreeRegistration(record: record, repositoryURL: repositoryURL)

        _ = try runGit(["worktree", "remove", record.workspacePath], in: repositoryURL)

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], in: repositoryURL).standardOutput
        guard !isRegistered(workspacePath: record.workspacePath, inWorktreeList: worktreeList) else {
            throw WorkspaceGuardError.gitCommandFailed(
                arguments: ["worktree", "list"],
                exitCode: 0,
                stderr: "worktree \(record.workspacePath) stayed registered after removal"
            )
        }

        do {
            try FileManager.default.removeItem(at: manifestURL)
        } catch {
            throw WorkspaceGuardError.storeRecordFailed(reason: "manifest removal failed: \(error)")
        }
        holdings[workspaceID] = nil
        removeEmptyDirectories(upTo: worktreesRoot, from: workspaceURL.deletingLastPathComponent())
        removeEmptyDirectories(upTo: registryRoot, from: manifestURL.deletingLastPathComponent())

        // The retired event is recorded only after the mutation succeeded: recording it
        // first could announce a retirement that then failed and left the manifest alive.
        if let events {
            do {
                try await events.recordWorkspaceEvent(makeRetiredEvent(record: record))
            } catch {
                throw WorkspaceGuardError.storeRecordFailed(reason: "workspace.retired event could not be recorded: \(error)")
            }
        }
    }

    /// Releases the live holding of an attempt once its work is provably finished.
    ///
    /// This is part of the `WorkspaceManaging` port so a port-only caller can complete
    /// create → release → retire without the concrete actor. A release whose attempt does
    /// not match the live holding is a no-op, and the workspace then maps back to `.idle`
    /// for preflight and recovery.
    func releaseOwnedWorkspace(workspaceID: UUID, attemptID: UUID) async {
        guard let holding = holdings[workspaceID], holding.attemptID == attemptID else { return }
        holdings[workspaceID] = nil
    }

    // MARK: - Layout

    private var registryRoot: URL {
        configuration.authorizedRoot.appendingPathComponent("registry", isDirectory: true)
    }

    private var worktreesRoot: URL {
        configuration.authorizedRoot.appendingPathComponent("worktrees", isDirectory: true)
    }

    private func manifestURL(projectID: UUID, taskID: UUID, workspaceID: UUID) -> URL {
        registryRoot.appendingPathComponent(
            "\(projectID.uuidString)/\(taskID.uuidString)/\(workspaceID.uuidString).json",
            isDirectory: false
        )
    }

    private func workspaceURL(projectID: UUID, taskID: UUID, workspaceID: UUID) -> URL {
        worktreesRoot.appendingPathComponent(
            "\(projectID.uuidString)/\(taskID.uuidString)/\(workspaceID.uuidString)",
            isDirectory: true
        )
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardized.resolvingSymlinksInPath().path
    }

    private func canonicalPath(_ path: String) -> String {
        canonicalPath(URL(fileURLWithPath: path))
    }

    // MARK: - Git invocations (fixed argv only)

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> GitCommandResult {
        let result = try runGitAllowingFailure(arguments, in: directory)
        guard result.exitCode == 0 else {
            throw WorkspaceGuardError.gitCommandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                stderr: clip(result.standardError, limit: Self.maxStatusCharacters)
            )
        }
        return result
    }

    private func runGitAllowingFailure(_ arguments: [String], in directory: URL) throws -> GitCommandResult {
        do {
            return try runner.run(executable: "git", arguments: arguments, directory: directory)
        } catch let error as WorkspaceGuardError {
            // The runner's typed timeout must survive the wrap so callers can act on it.
            throw error
        } catch {
            throw WorkspaceGuardError.gitCommandFailed(arguments: arguments, exitCode: -1, stderr: "\(error)")
        }
    }

    private func repositoryCommonDirIdentity(_ repositoryURL: URL) throws -> String {
        let result = try runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repositoryURL)
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw WorkspaceGuardError.notAGitRepository(path: canonicalPath(repositoryURL))
        }
        return canonicalPath(value)
    }

    private func isGitWorkTree(_ repositoryURL: URL) throws -> Bool {
        let result = try runGitAllowingFailure(["rev-parse", "--is-inside-work-tree"], in: repositoryURL)
        return result.exitCode == 0 && result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func normalizedCommitSHA(_ sha: String) throws -> String {
        let normalized = sha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(of: Self.commitObjectNamePattern, options: .regularExpression) != nil else {
            throw WorkspaceGuardError.invalidBase(sha: sha)
        }
        return normalized
    }

    private func verifyCommitExists(_ sha: String, repositoryURL: URL) throws {
        let result = try runGitAllowingFailure(["rev-parse", "--verify", "\(sha)^{commit}"], in: repositoryURL)
        guard result.exitCode == 0 else {
            throw WorkspaceGuardError.baseNotFound(sha: sha)
        }
        let resolved = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved == sha else {
            throw WorkspaceGuardError.baseNotFound(sha: sha)
        }
    }

    // MARK: - Guard checks

    private func validateProjectIdentity(project: CodingProject, task: CodingTask) throws {
        guard task.projectID == project.id else {
            throw WorkspaceGuardError.taskProjectMismatch(taskID: task.id, projectID: project.id)
        }
        let repositoryURL = URL(fileURLWithPath: project.repositoryPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceGuardError.notAGitRepository(path: project.repositoryPath)
        }
        if !configuration.authorizedProjectRoots.isEmpty {
            let isAuthorized = configuration.authorizedProjectRoots.contains { root in
                GoalSafety.isPathInsideSandbox(path: project.repositoryPath, sandboxRoot: root.path)
            }
            guard isAuthorized else {
                throw WorkspaceGuardError.outsideAuthorizedScope(path: canonicalPath(repositoryURL))
            }
        }
        guard try isGitWorkTree(repositoryURL) else {
            throw WorkspaceGuardError.notAGitRepository(path: canonicalPath(repositoryURL))
        }
    }

    private func assertWorkspaceRootOutsideRepository(project: CodingProject) throws {
        let root = configuration.authorizedRoot
        if GoalSafety.isPathInsideSandbox(path: root.path, sandboxRoot: project.repositoryPath) {
            throw WorkspaceGuardError.workspaceRootInsideRepository(
                root: canonicalPath(root),
                repository: canonicalPath(project.repositoryPath)
            )
        }
    }

    private func assertTargetIsSafe(projectID: UUID, taskID: UUID, workspaceID: UUID?) throws {
        let taskDirectory = worktreesRoot.appendingPathComponent(
            "\(projectID.uuidString)/\(taskID.uuidString)",
            isDirectory: true
        )
        try assertPathInsideAuthorizedRoot(taskDirectory)
        if let workspaceID {
            try assertPathInsideAuthorizedRoot(workspaceURL(projectID: projectID, taskID: taskID, workspaceID: workspaceID))
        }
    }

    private func assertPathInsideAuthorizedRoot(_ candidate: URL) throws {
        let root = configuration.authorizedRoot
        if let symlink = firstSymlinkComponent(of: candidate, below: root) {
            throw WorkspaceGuardError.symlinkEscape(path: canonicalPath(symlink))
        }
        guard GoalSafety.isPathInsideSandbox(path: candidate.path, sandboxRoot: root.path) else {
            throw WorkspaceGuardError.outsideAuthorizedScope(path: canonicalPath(candidate))
        }
    }

    /// Returns the first existing path component below `root` that is a symbolic link.
    ///
    /// Existing components are inspected with `lstat` semantics, so a link that points
    /// back inside the root is still refused: managed worktree paths must be real directories.
    private func firstSymlinkComponent(of candidate: URL, below root: URL) -> URL? {
        let rootComponents = root.standardized.pathComponents
        let candidateComponents = candidate.standardized.pathComponents
        guard candidateComponents.count > rootComponents.count else { return nil }
        for index in rootComponents.count..<candidateComponents.count {
            let prefix = NSString.path(withComponents: Array(candidateComponents.prefix(index + 1)))
            guard FileManager.default.fileExists(atPath: prefix) else { break }
            let attributes = try? FileManager.default.attributesOfItem(atPath: prefix)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                return URL(fileURLWithPath: prefix)
            }
        }
        return nil
    }

    private func verifySourceIsClean(project: CodingProject) throws {
        let repositoryURL = URL(fileURLWithPath: project.repositoryPath)
        let result = try runGit(["status", "--porcelain=v1", "--untracked-files=all"], in: repositoryURL)
        let status = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.isEmpty else {
            throw WorkspaceGuardError.worktreeDirty(
                path: canonicalPath(repositoryURL),
                status: clip(status, limit: Self.maxStatusCharacters)
            )
        }
    }

    private func verifyBranchIsWritable(project: CodingProject) throws {
        let repositoryURL = URL(fileURLWithPath: project.repositoryPath)
        let result = try runGitAllowingFailure(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repositoryURL)
        // A detached HEAD has no branch to protect; only an actual protected branch refuses.
        guard result.exitCode == 0 else { return }
        let branch = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        let protectedBranches = project.protectedRefs.isEmpty ? ["main", "master"] : project.protectedRefs
        guard GoalSafety.mayWriteToBranch(branch, protectedBranches: protectedBranches) else {
            throw WorkspaceGuardError.protectedBranch(branch: branch)
        }
    }

    // MARK: - Manifests

    private func publishableManifests(projectID: UUID, taskID: UUID) throws -> [URL] {
        let directory = registryRoot.appendingPathComponent(
            "\(projectID.uuidString)/\(taskID.uuidString)",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Locates the manifest for one workspace identity deterministically.
    ///
    /// Enumeration order is not stable, so candidates are sorted by path and the one
    /// registered at the manifest's own derived location wins; if none matches (a
    /// dishonest or misplaced manifest), the first sorted candidate is returned so
    /// `validatedRecord` can refuse it with a deterministic error instead of a random one.
    private func findManifest(workspaceID: UUID) -> URL? {
        let fileName = "\(workspaceID.uuidString).json"
        guard FileManager.default.fileExists(atPath: registryRoot.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(at: registryRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        var candidates: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            candidates.append(url)
        }
        let sorted = candidates.sorted { canonicalPath($0) < canonicalPath($1) }
        guard let first = sorted.first else { return nil }
        return sorted.first(where: isRegisteredAtDerivedLocation) ?? first
    }

    private func isRegisteredAtDerivedLocation(_ manifestURL: URL) -> Bool {
        guard let manifest = try? WorkspaceManifest.decode(from: Data(contentsOf: manifestURL)) else { return false }
        let derived = self.manifestURL(
            projectID: manifest.projectID,
            taskID: manifest.taskID,
            workspaceID: manifest.workspaceID
        )
        return canonicalPath(derived) == canonicalPath(manifestURL)
    }

    private func validatedRecord(
        at manifestURL: URL,
        expectedWorkspaceID: UUID?,
        expectedProject: CodingProject?,
        expectedTaskID: UUID?
    ) throws -> WorkspaceRecord {
        let fileWorkspaceID = UUID(uuidString: manifestURL.deletingPathExtension().lastPathComponent)
        let manifest: WorkspaceManifest
        do {
            manifest = try WorkspaceManifest.decode(from: Data(contentsOf: manifestURL))
        } catch {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: fileWorkspaceID,
                reason: "manifest is not readable: \(error)"
            )
        }
        guard manifest.schemaVersion == WorkspaceManifest.currentSchemaVersion else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: manifest.workspaceID,
                reason: "unsupported manifest schema version \(manifest.schemaVersion)"
            )
        }
        guard fileWorkspaceID == manifest.workspaceID, expectedWorkspaceID == nil || expectedWorkspaceID == manifest.workspaceID else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: manifest.workspaceID,
                reason: "manifest identity does not match its file name"
            )
        }
        let derivedManifestURL = self.manifestURL(
            projectID: manifest.projectID,
            taskID: manifest.taskID,
            workspaceID: manifest.workspaceID
        )
        guard canonicalPath(manifestURL) == canonicalPath(derivedManifestURL) else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: manifest.workspaceID,
                reason: "manifest is registered at \(canonicalPath(manifestURL)) instead of \(canonicalPath(derivedManifestURL))"
            )
        }
        guard !manifest.nonce.isEmpty else {
            throw WorkspaceGuardError.foreignManifest(workspaceID: manifest.workspaceID, reason: "ownership nonce is empty")
        }
        guard manifest.baseSHA.range(of: Self.commitObjectNamePattern, options: .regularExpression) != nil else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: manifest.workspaceID,
                reason: "base \(manifest.baseSHA) is not a full commit object name"
            )
        }
        if let expectedProject {
            guard manifest.projectID == expectedProject.id else {
                throw WorkspaceGuardError.foreignManifest(
                    workspaceID: manifest.workspaceID,
                    reason: "manifest belongs to project \(manifest.projectID.uuidString)"
                )
            }
            guard canonicalPath(manifest.repositoryPath) == canonicalPath(expectedProject.repositoryPath) else {
                throw WorkspaceGuardError.foreignManifest(
                    workspaceID: manifest.workspaceID,
                    reason: "manifest repository path does not match the project"
                )
            }
        }
        if let expectedTaskID, manifest.taskID != expectedTaskID {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: manifest.workspaceID,
                reason: "manifest belongs to task \(manifest.taskID.uuidString)"
            )
        }
        let derivedWorkspaceURL = workspaceURL(
            projectID: manifest.projectID,
            taskID: manifest.taskID,
            workspaceID: manifest.workspaceID
        )
        guard canonicalPath(manifest.workspacePath) == canonicalPath(derivedWorkspaceURL) else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: manifest.workspaceID,
                reason: "manifest workspace path is not the authorized target"
            )
        }
        guard GoalSafety.isPathInsideSandbox(path: manifest.workspacePath, sandboxRoot: configuration.authorizedRoot.path) else {
            throw WorkspaceGuardError.outsideAuthorizedScope(path: canonicalPath(manifest.workspacePath))
        }
        let repositoryURL = URL(fileURLWithPath: manifest.repositoryPath)
        let actualCommonDir = try repositoryCommonDirIdentity(repositoryURL)
        guard actualCommonDir == manifest.commonDirIdentity else {
            throw WorkspaceGuardError.commonDirMismatch(expected: manifest.commonDirIdentity, actual: actualCommonDir)
        }
        return manifest.record
    }

    private func writeManifestAtomically(_ manifest: WorkspaceManifest, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifest.encoded().write(to: url, options: [.atomic])
        } catch {
            throw WorkspaceGuardError.storeRecordFailed(reason: "could not write workspace manifest: \(error)")
        }
    }

    private func makeEvent(manifest: WorkspaceManifest) throws -> CodingTaskEvent {
        CodingTaskEvent(
            taskID: manifest.taskID,
            attemptID: manifest.attemptID,
            timestamp: manifest.createdAt,
            kind: "workspace.created",
            redactedPayload: try manifest.payloadString()
        )
    }

    private struct RetiredWorkspacePayload: Codable {
        let workspaceID: UUID
        let taskID: UUID
        let attemptID: UUID
        let nonce: String
    }

    private func makeRetiredEvent(record: WorkspaceRecord) throws -> CodingTaskEvent {
        let payload = RetiredWorkspacePayload(
            workspaceID: record.workspaceID,
            taskID: record.taskID,
            attemptID: record.attemptID,
            nonce: record.nonce
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let string = String(data: try encoder.encode(payload), encoding: .utf8) else {
            throw WorkspaceGuardError.storeRecordFailed(reason: "workspace.retired payload is not valid UTF-8")
        }
        return CodingTaskEvent(
            taskID: record.taskID,
            attemptID: record.attemptID,
            timestamp: Date(),
            kind: "workspace.retired",
            redactedPayload: string
        )
    }

    // MARK: - Ownership and cleanliness

    private func holder(for record: WorkspaceRecord) -> WorkspaceHolder {
        guard let holding = holdings[record.workspaceID],
            holding.taskID == record.taskID,
            holding.attemptID == record.attemptID,
            holding.nonce == record.nonce
        else {
            return .idle
        }
        return .active(attemptID: holding.attemptID)
    }

    private func workspaceCleanliness(_ record: WorkspaceRecord) -> WorkspaceCleanliness {
        let workspaceURL = URL(fileURLWithPath: record.workspacePath)
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            return .unreadable(reason: "workspace path is missing")
        }
        do {
            let result = try runGit(["status", "--porcelain=v1", "--untracked-files=all"], in: workspaceURL)
            let status = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return status.isEmpty ? .clean : .dirty(status: clip(status, limit: Self.maxStatusCharacters))
        } catch {
            return .unreadable(reason: "\(error)")
        }
    }

    private func verifyWorktreeRegistration(record: WorkspaceRecord, repositoryURL: URL) throws {
        let worktreeList = try runGit(["worktree", "list", "--porcelain"], in: repositoryURL).standardOutput
        guard isRegistered(workspacePath: record.workspacePath, inWorktreeList: worktreeList) else {
            throw WorkspaceGuardError.foreignManifest(
                workspaceID: record.workspaceID,
                reason: "workspace is not registered as a Git worktree"
            )
        }
    }

    private func isRegistered(workspacePath: String, inWorktreeList worktreeList: String) -> Bool {
        worktreeList.split(separator: "\n").contains { line in
            line.hasPrefix("worktree ") && canonicalPath(String(line.dropFirst("worktree ".count))) == workspacePath
        }
    }

    // MARK: - Cleanup

    private func rollbackWorktree(_ workspaceURL: URL, manifestURL: URL?, repositoryURL: URL) {
        _ = try? runner.run(
            executable: "git",
            arguments: ["worktree", "remove", workspaceURL.path],
            directory: repositoryURL
        )
        if FileManager.default.fileExists(atPath: workspaceURL.path) {
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        if let manifestURL {
            try? FileManager.default.removeItem(at: manifestURL)
        }
        removeEmptyDirectories(upTo: worktreesRoot, from: workspaceURL.deletingLastPathComponent())
        if let manifestURL {
            removeEmptyDirectories(upTo: registryRoot, from: manifestURL.deletingLastPathComponent())
        }
    }

    /// Removes now-empty bookkeeping directories upward, never touching the root itself.
    private func removeEmptyDirectories(upTo root: URL, from directory: URL) {
        let rootPath = canonicalPath(root)
        var current = directory.standardized
        while canonicalPath(current) != rootPath, canonicalPath(current).hasPrefix(rootPath + "/") {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path), contents.isEmpty else {
                return
            }
            guard (try? FileManager.default.removeItem(at: current)) != nil else { return }
            current = current.deletingLastPathComponent()
        }
    }

    private func clip(_ text: String, limit: Int) -> String {
        String(text.prefix(limit))
    }
}

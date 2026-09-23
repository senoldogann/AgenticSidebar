import Foundation

// MARK: - Ownership model

/// Live holder of a managed workspace.
///
/// `active` is decided by this process's live-holder registry: a workspace becomes
/// active when `createOwnedWorkspace` succeeds for a live attempt and returns to
/// idle when that attempt is explicitly released or the workspace is retired.
/// A workspace persisted by an earlier process (crash or relaunch) has no live
/// holder, and that is exactly what the recovery layer needs before it may settle
/// a dangling attempt.
enum WorkspaceHolder: Sendable, Equatable {
    /// A live attempt holds the workspace; it must not be disturbed or retired.
    case active(attemptID: UUID)
    /// The workspace persists but no live attempt holds it in this process.
    case idle
}

/// Immutable provenance of one managed workspace, mirrored by its on-disk manifest.
struct WorkspaceRecord: Sendable, Equatable {
    let workspaceID: UUID
    let projectID: UUID
    let taskID: UUID
    let attemptID: UUID
    let repositoryPath: String
    let workspacePath: String
    let commonDirIdentity: String
    let baseSHA: String
    let nonce: String
    let createdAt: Date
}

/// Baseline commit a workspace is created from.
///
/// Only a full commit object name is accepted; a branch or tag is resolved by the
/// caller before the workspace port is invoked so the recorded base can never be
/// a moving reference.
struct WorkspaceBase: Sendable, Equatable {
    let commitSHA: String
}

// MARK: - Guard errors

/// Guard-specific refusals raised before any mutation.
///
/// Every case carries a stable `WORKTREE_*` code token so callers, reports and
/// tests can act on the exact guard that refused the operation.
enum WorkspaceGuardError: LocalizedError, Equatable, Sendable {
    /// Kaynak depoda izlenen/izlenmeyen değişiklik var.
    /// Artık uygulanmaz (her oluşturma kirli kaynaktan yeni `agentic/w-*`
    /// dalında devam eder); eski kayıtlarla uyumluluk için tutulur.
    case worktreeDirty(path: String, status: String)
    /// The source repository is checked out on a protected branch.
    /// Artık uygulanmaz (çalışma alanı yeni `agentic/w-*` dalında kurulduğu
    /// için korumalı checkout engel değildir); eski kayıtlarla uyumluluk için tutulur.
    case protectedBranch(branch: String)
    /// A symbolic link would carry the workspace outside its authorized root.
    case symlinkEscape(path: String)
    /// A path is outside the authorized project or workspace scope.
    case outsideAuthorizedScope(path: String)
    /// The app-owned workspace root may not live inside a source repository.
    case workspaceRootInsideRepository(root: String, repository: String)
    /// A manifest does not match its registry location, project or repository.
    case foreignManifest(workspaceID: UUID?, reason: String)
    /// A manifest records a Git common dir that no longer matches the repository.
    case commonDirMismatch(expected: String, actual: String)
    /// No manifest exists for the requested workspace identity.
    case unknownWorkspace(workspaceID: UUID)
    /// The manifest exists but its worktree path is gone.
    case workspacePathMissing(workspaceID: UUID, path: String)
    /// A clean retirement was requested for a worktree that still has changes.
    case dirtyOwnedWorkspace(workspaceID: UUID, manualInspectionPath: String)
    /// A live attempt still holds the workspace.
    case activelyOwnedWorkspace(workspaceID: UUID, attemptID: UUID)
    /// An owned workspace already exists for the task; retirement or reuse must be explicit.
    case workspaceAlreadyOwned(workspaceID: UUID)
    /// The task does not belong to the project that is being preflighted.
    case taskProjectMismatch(taskID: UUID, projectID: UUID)
    /// The supplied attempt belongs to a different task.
    case attemptTaskMismatch(taskID: UUID, attemptID: UUID)
    /// The repository path is missing or is not a Git work tree.
    case notAGitRepository(path: String)
    /// The requested base is not a full commit object name.
    case invalidBase(sha: String)
    /// The requested base does not resolve to a commit in the repository.
    case baseNotFound(sha: String)
    /// A fixed argv Git invocation failed.
    case gitCommandFailed(arguments: [String], exitCode: Int32, stderr: String)
    /// A fixed argv invocation exceeded its wall-clock budget and was terminated.
    case gitTimedOut(executable: String, arguments: [String], timeout: TimeInterval)
    /// The workspace layer could not inspect the repository; the reason is not a Git exit code.
    case inspectionUnavailable(reason: String)
    /// The owned workspace working tree could not be read for cleanliness.
    case cleanlinessUnreadable(reason: String)
    /// The manifest could not be recorded atomically in the task store.
    case storeRecordFailed(reason: String)
    /// The supplied approval does not authorize this retirement.
    case approvalRejected(reason: String)
    /// The project is unknown to the injected resolver.
    case projectNotFound(projectID: UUID)

    /// Stable guard code reported alongside every refusal.
    var code: String {
        switch self {
        case .worktreeDirty: return "WORKTREE_DIRTY"
        case .protectedBranch: return "WORKTREE_PROTECTED_BRANCH"
        case .symlinkEscape: return "WORKTREE_SYMLINK_ESCAPE"
        case .outsideAuthorizedScope: return "WORKTREE_SCOPE_VIOLATION"
        case .workspaceRootInsideRepository: return "WORKTREE_ROOT_INSIDE_REPOSITORY"
        case .foreignManifest: return "WORKTREE_FOREIGN_MANIFEST"
        case .commonDirMismatch: return "WORKTREE_COMMON_DIR_MISMATCH"
        case .unknownWorkspace: return "WORKTREE_UNKNOWN"
        case .workspacePathMissing: return "WORKTREE_PATH_MISSING"
        case .dirtyOwnedWorkspace: return "WORKTREE_OWNED_DIRTY"
        case .activelyOwnedWorkspace: return "WORKTREE_ACTIVE"
        case .workspaceAlreadyOwned: return "WORKTREE_ALREADY_OWNED"
        case .taskProjectMismatch: return "WORKTREE_TASK_PROJECT_MISMATCH"
        case .attemptTaskMismatch: return "WORKTREE_ATTEMPT_TASK_MISMATCH"
        case .notAGitRepository: return "WORKTREE_NOT_A_REPOSITORY"
        case .invalidBase: return "WORKTREE_INVALID_BASE"
        case .baseNotFound: return "WORKTREE_BASE_NOT_FOUND"
        case .gitCommandFailed: return "WORKTREE_GIT_FAILED"
        case .gitTimedOut: return "WORKTREE_GIT_TIMEOUT"
        case .inspectionUnavailable: return "WORKTREE_INSPECTION_UNAVAILABLE"
        case .cleanlinessUnreadable: return "WORKTREE_CLEANLINESS_UNREADABLE"
        case .storeRecordFailed: return "WORKTREE_STORE_RECORD_FAILED"
        case .approvalRejected: return "WORKTREE_APPROVAL_REJECTED"
        case .projectNotFound: return "WORKTREE_PROJECT_UNKNOWN"
        }
    }

    var errorDescription: String? {
        switch self {
        case .worktreeDirty(let path, let status):
            return "\(code): source repository at \(path) has uncommitted changes: \(status)"
        case .protectedBranch(let branch):
            return "\(code): source repository is checked out on protected branch \(branch)"
        case .symlinkEscape(let path):
            return "\(code): symbolic link \(path) escapes the authorized workspace root"
        case .outsideAuthorizedScope(let path):
            return "\(code): path \(path) is outside the authorized scope"
        case .workspaceRootInsideRepository(let root, let repository):
            return "\(code): workspace root \(root) lives inside repository \(repository)"
        case .foreignManifest(let workspaceID, let reason):
            return "\(code): manifest \(workspaceID?.uuidString ?? "<unknown>") is not owned by this project: \(reason)"
        case .commonDirMismatch(let expected, let actual):
            return "\(code): Git common dir \(actual) does not match manifest identity \(expected)"
        case .unknownWorkspace(let workspaceID):
            return "\(code): no managed workspace \(workspaceID.uuidString)"
        case .workspacePathMissing(let workspaceID, let path):
            return "\(code): workspace \(workspaceID.uuidString) path \(path) is missing"
        case .dirtyOwnedWorkspace(let workspaceID, let manualInspectionPath):
            return "\(code): workspace \(workspaceID.uuidString) is dirty; inspect manually at \(manualInspectionPath)"
        case .activelyOwnedWorkspace(let workspaceID, let attemptID):
            return "\(code): workspace \(workspaceID.uuidString) is actively held by attempt \(attemptID.uuidString)"
        case .workspaceAlreadyOwned(let workspaceID):
            return "\(code): workspace \(workspaceID.uuidString) is already owned; retire or reuse it explicitly"
        case .taskProjectMismatch(let taskID, let projectID):
            return "\(code): task \(taskID.uuidString) does not belong to project \(projectID.uuidString)"
        case .attemptTaskMismatch(let taskID, let attemptID):
            return "\(code): attempt \(attemptID.uuidString) does not belong to task \(taskID.uuidString)"
        case .notAGitRepository(let path):
            return "\(code): \(path) is not a Git work tree"
        case .invalidBase(let sha):
            return "\(code): base \(sha) is not a full commit object name"
        case .baseNotFound(let sha):
            return "\(code): base commit \(sha) does not exist in the repository"
        case .gitCommandFailed(let arguments, let exitCode, let stderr):
            return "\(code): git \(arguments.joined(separator: " ")) exited \(exitCode): \(stderr)"
        case .gitTimedOut(let executable, let arguments, let timeout):
            return "\(code): \(executable) \(arguments.joined(separator: " ")) did not finish within \(timeout)s and was terminated"
        case .inspectionUnavailable(let reason):
            return "\(code): workspace inspection is unavailable: \(reason)"
        case .cleanlinessUnreadable(let reason):
            return "\(code): owned workspace cleanliness could not be read: \(reason)"
        case .storeRecordFailed(let reason):
            return "\(code): workspace manifest could not be recorded: \(reason)"
        case .approvalRejected(let reason):
            return "\(code): retirement approval rejected: \(reason)"
        case .projectNotFound(let projectID):
            return "\(code): project \(projectID.uuidString) is unknown"
        }
    }
}

// MARK: - Preflight and inspection

/// Preflight answer for one task before any worktree is created.
enum WorkspacePreflight: Sendable, Equatable {
    /// A valid owned workspace exists; `holder` separates a live attempt from an idle record.
    case owned(WorkspaceRecord, holder: WorkspaceHolder)
    /// No owned workspace exists; creation is allowed once the caller supplies an attempt.
    case notOwned(reason: String)
    /// A guard refused the repository or an existing manifest; nothing may be mutated.
    case blocked(WorkspaceGuardError)
    /// The workspace layer could not be inspected (process, filesystem or Git failure).
    case unavailable(reason: String)
}

/// Working-tree cleanliness reported by inspection.
enum WorkspaceCleanliness: Sendable, Equatable {
    case clean
    case dirty(status: String)
    case unreadable(reason: String)
}

/// Full inspection report for one owned workspace.
struct WorkspaceInspectionReport: Sendable, Equatable {
    let record: WorkspaceRecord
    let holder: WorkspaceHolder
    let cleanliness: WorkspaceCleanliness
}

/// Inspection answer for one workspace identity.
enum WorkspaceInspection: Sendable, Equatable {
    case present(WorkspaceInspectionReport)
    case unknown(workspaceID: UUID)
    case rejected(WorkspaceGuardError)
}

// MARK: - Ports

/// Managed workspace port: preflight, exact creation, inspection, release and guarded retirement.
///
/// Lifecycle contract: a workspace created through this port is held by the creating
/// attempt until `releaseOwnedWorkspace` is called with the same `workspaceID` and
/// `attemptID`. Retirement refuses a live holder with `WORKTREE_ACTIVE`, so a port-only
/// caller completes the lifecycle as create → release → retire; release is intentionally
/// part of the port rather than an implementation detail so that callers never need the
/// concrete actor to finish an attempt.
protocol WorkspaceManaging: Sendable {
    func preflight(project: CodingProject, task: CodingTask) async -> WorkspacePreflight
    /// Resolves the immutable repository HEAD commit a fresh workspace is based on.
    func resolveBase(task: CodingTask) async throws -> WorkspaceBase
    func createOwnedWorkspace(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord
    func inspect(workspaceID: UUID) async -> WorkspaceInspection
    /// Releases the live holding of a finished attempt; a mismatched attempt is a no-op.
    func releaseOwnedWorkspace(workspaceID: UUID, attemptID: UUID) async
    func retire(workspaceID: UUID, approval: TaskApproval) async throws
}

/// Resolves the registered project for a task, including its repository path and protected refs.
protocol WorkspaceProjectResolving: Sendable {
    func resolveProject(id: UUID) async -> CodingProject?
}

/// Resolves a task for ports that only carry a task identifier.
///
/// Resolution is throwing so a store failure is never flattened into "task unknown":
/// callers can distinguish a genuinely absent task from an unreadable store.
protocol CodingTaskResolving: Sendable {
    func resolveTask(id: UUID) async throws -> CodingTask?
}

/// Narrow port for the atomic persisted record of a workspace manifest.
///
/// `SQLiteTaskStore` satisfies it through `appendEvent`, so the record lands in the
/// same transactional store as tasks and attempts without widening the workspace
/// layer into the full repository protocol.
protocol WorkspaceEventRecording: Sendable {
    func recordWorkspaceEvent(_ event: CodingTaskEvent) async throws
}

extension SQLiteTaskStore: CodingTaskResolving {
    func resolveTask(id: UUID) async throws -> CodingTask? {
        try await task(id: id)
    }
}

extension SQLiteTaskStore: WorkspaceEventRecording {
    func recordWorkspaceEvent(_ event: CodingTaskEvent) async throws {
        try await appendEvent(event)
    }
}

// MARK: - Port adapters

/// Backs the scheduler's `TaskWorkspacePreflightPort` with a `WorkspaceManaging` implementation.
///
/// Ownership mapping: the scheduler leases the repository before it claims an attempt,
/// so the repository lease — not the workspace holder — fences concurrent writers. A
/// valid workspace (active or idle) is therefore offered as `.owned`; the workspace
/// manager decides ownership from the manifest and Git registration before it looks at
/// source cleanliness, so a dirty source checkout can no longer mask an existing owned
/// workspace as `.unavailable`. A guard refusal or an inspection failure becomes
/// `.unavailable` and everything else `.notOwned`. The idle-versus-active distinction
/// matters to the recovery adapter below, not here.
struct GitWorkspaceSchedulerAdapter: TaskWorkspacePreflightPort {
    let manager: any WorkspaceManaging
    let projects: any WorkspaceProjectResolving
    let tasks: any CodingTaskResolving

    func preflight(projectID: UUID, taskID: UUID) async -> TaskWorkspacePreflightResult {
        guard let project = await projects.resolveProject(id: projectID) else {
            return .unavailable(reason: "project \(projectID.uuidString) is unknown")
        }
        let task: CodingTask
        do {
            guard let resolved = try await tasks.resolveTask(id: taskID) else {
                return .unavailable(reason: "task \(taskID.uuidString) is unknown")
            }
            task = resolved
        } catch {
            return .unavailable(reason: "task \(taskID.uuidString) resolution failed: \(error)")
        }
        switch await manager.preflight(project: project, task: task) {
        case .owned(let record, _):
            return .owned(
                TaskWorkspaceDescriptor(
                    workspaceID: record.workspaceID,
                    workspacePath: record.workspacePath,
                    repositoryPath: record.repositoryPath
                )
            )
        case .notOwned(let reason):
            return .notOwned(reason: reason)
        case .blocked(let error):
            return .unavailable(reason: "\(error.code): \(error.localizedDescription)")
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }
}

/// Backs the scheduler's `TaskWorkspaceProvisioningPort` with a `WorkspaceManaging` implementation.
///
/// `create` maps directly to `createOwnedWorkspace`, so every manager guard (authorized
/// root, exact identity) still applies unchanged, and `resolveBase` maps to the
/// manager's validated HEAD resolution. Source cleanliness is deliberately not a
/// guard: every creation opens a fresh `agentic/w-*` branch at the base commit and
/// leaves the source checkout untouched.
///
/// `discardUnclaimed` is guard-safe by construction: the creating attempt's live holding is
/// released first (a mismatched attempt is a no-op release, so a workspace held by another
/// attempt stays visibly active), then the idle workspace is retired with an internally
/// issued `discardWorkspace` approval bound to the exact task, the exact attempt and the
/// workspace base SHA. A workspace that is already unknown is treated as discarded; a
/// rejected manifest is surfaced instead of silently ignored. No manager guard is relaxed
/// and the approval is never reused across attempts.
struct GitWorkspaceSchedulerProvisioningAdapter: TaskWorkspaceProvisioningPort {
    let manager: any WorkspaceManaging
    let approvalActor: String

    func resolveBase(for task: CodingTask) async throws -> WorkspaceBase {
        try await manager.resolveBase(task: task)
    }

    func create(task: CodingTask, attempt: TaskAttempt, base: WorkspaceBase) async throws -> WorkspaceRecord {
        try await manager.createOwnedWorkspace(task: task, attempt: attempt, base: base)
    }

    func discardUnclaimed(workspaceID: UUID, attemptID: UUID) async throws {
        await manager.releaseOwnedWorkspace(workspaceID: workspaceID, attemptID: attemptID)
        switch await manager.inspect(workspaceID: workspaceID) {
        case .unknown:
            // The workspace is already gone; there is nothing left to retire.
            return
        case .rejected(let error):
            throw error
        case .present(let report):
            let approval = TaskApproval(
                id: UUID(),
                taskID: report.record.taskID,
                attemptID: attemptID,
                fingerprint: report.record.baseSHA,
                actor: approvalActor,
                timestamp: Date(),
                action: .discardWorkspace
            )
            try await manager.retire(workspaceID: workspaceID, approval: approval)
        }
    }
}

/// Backs the recovery layer's `TaskWorkspaceOwnershipInspecting` port with a `WorkspaceManaging` implementation.
///
/// Ownership mapping:
/// - a live holder maps to `.activelyOwned`, so recovery never settles work it cannot prove stopped;
/// - a persisted-but-idle manifest maps to `.notActivelyOwned(repositoryPath:)`, so the dangling
///   attempt's repository lease can be released by exact identity;
/// - a live holder from a different attempt generation, a missing workspace or a rejected/foreign
///   manifest maps to `.unknown`, which keeps recovery conservative.
struct GitWorkspaceRecoveryAdapter: TaskWorkspaceOwnershipInspecting {
    let manager: any WorkspaceManaging

    func workspaceStatus(for attempt: TaskAttempt) async -> TaskWorkspaceOwnershipStatus {
        guard let workspaceID = attempt.workspaceID else {
            return .unknown(reason: "attempt \(attempt.id.uuidString) has no workspace identity")
        }
        switch await manager.inspect(workspaceID: workspaceID) {
        case .present(let report):
            guard report.record.taskID == attempt.taskID else {
                return .unknown(reason: "workspace \(workspaceID.uuidString) belongs to another task")
            }
            let descriptor = TaskWorkspaceDescriptor(
                workspaceID: report.record.workspaceID,
                workspacePath: report.record.workspacePath,
                repositoryPath: report.record.repositoryPath
            )
            switch report.holder {
            case .active(let attemptID) where attemptID == attempt.id:
                return .activelyOwned(descriptor)
            case .active:
                return .unknown(reason: "workspace \(workspaceID.uuidString) is held by a different attempt")
            case .idle:
                return .notActivelyOwned(repositoryPath: report.record.repositoryPath)
            }
        case .unknown:
            return .unknown(reason: "no managed workspace record \(workspaceID.uuidString)")
        case .rejected(let error):
            return .unknown(reason: "\(error.code): \(error.localizedDescription)")
        }
    }
}

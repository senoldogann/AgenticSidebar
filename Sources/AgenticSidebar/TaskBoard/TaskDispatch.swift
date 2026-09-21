import Foundation

/// A permission request raised by one running agent attempt.
///
/// `patterns` carries the paths the request names. An empty list means the request
/// names none; a file-mutating tool with no patterns can never be proven in-workspace.
///
/// `delegationTarget` carries the `task` tool's `subagent_type`: the scheduler's
/// deny-unless-safe decision for delegations is made on it, never on the display
/// text. `nil` for every other tool, and for a `task` request that names none —
/// a targetless delegation fails closed.
struct TaskRunApprovalRequest: Sendable, Equatable {
    let id: String
    let toolName: String
    let patterns: [String]
    let delegationTarget: String?
}

/// The reply to one permission request. A denial always names its reason.
enum TaskRunApprovalReply: Sendable, Equatable {
    case approveOnce
    case deny(reason: String)
}

/// Resolver the dispatch port receives and the scheduler applies to every request.
typealias TaskRunApprovalResolver = @Sendable (TaskRunApprovalRequest) async -> TaskRunApprovalReply

/// One resolved permission request, recorded on the dispatch report.
struct TaskRunApprovalDecision: Sendable, Equatable {
    let requestID: String
    let toolName: String
    let reply: TaskRunApprovalReply
}

/// Everything the dispatch port needs to start one accepted attempt.
struct TaskRunRequest: Sendable, Equatable {
    let task: CodingTask
    let attempt: TaskAttempt
    let workspace: TaskWorkspaceDescriptor
    let approvalPolicy: ToolApprovalPolicy
    let deadline: Date?
}

/// Handle to one live run started by the dispatch port.
///
/// `events` must be delivered through a bounded stream: the scheduler consumes it
/// serially, one event at a time, and expects `cancel()` to finish the stream so a
/// cancelled run always reaches its final event. `cancel()` never touches any other
/// attempt, task or process.
protocol TaskRunSession: Sendable {
    var events: AsyncStream<CodingAgentEvent> { get }
    func cancel() async
}

/// Starts a coding agent for an attempt after every dispatch gate accepted it.
///
/// The resolver is handed to the port so a provider that answers permission
/// requests inline can apply the same deny-unless-safe decision the scheduler
/// applies while consuming `.approvalRequested` events.
protocol TaskRunningPort: Sendable {
    func start(
        _ request: TaskRunRequest,
        approvalResolver: @escaping TaskRunApprovalResolver
    ) async throws -> TaskRunSession
}

// MARK: - Deny-unless-safe approval policy

/// MVP permission policy for live dispatch: deny unless the existing
/// `ToolApprovalPolicy` semantics prove a safe in-workspace action.
///
/// Stricter than `ToolApprovalPolicy.approveSafe.automaticReply`: shell commands are
/// refused even when the policy whitelist would trust them, network tools and
/// computer use are always refused, and a named pattern outside the owned workspace
/// is always refused. No new policy engine: the safe-tool allow-list, the
/// file-mutation/pattern rule and the workspace scope check are the existing
/// policy's own semantics.
enum TaskRunApprovalPolicy {
    static func resolve(
        toolName: String,
        patterns: [String],
        workspacePath: String,
        delegationTarget: String?
    ) -> TaskRunApprovalReply {
        // Plan aşaması delegasyon yaptırımı: gözetimsiz koşuda `task`
        // delegasyonu yalnız araştırma hedefine bir kez onaylanır. Yazılabilir
        // ya da hedefsiz delegasyon reddedilir — kullanıcı diyaloğu yoktur,
        // karar ret yönünde verilir.
        if toolName.lowercased() == "task" {
            guard ToolApprovalPolicy.isResearchDelegationTarget(delegationTarget) else {
                return .deny(reason: "taskDelegationOutsideResearchTarget:\(delegationTarget ?? "unknown")")
            }
            return .approveOnce
        }
        guard !ToolApprovalPolicy.isComputerUseTool(toolName) else {
            return .deny(reason: "computerUseRequiresHumanApproval")
        }
        guard !isNetworkTool(toolName) else {
            return .deny(reason: "networkRequiresHumanApproval")
        }
        // Every shell tool name fails this allow-list on purpose: the MVP never runs
        // a command unattended, not even one the trusted-command whitelist would accept.
        guard ToolApprovalPolicy.isSafeWithoutAsking(toolName) else {
            return .deny(reason: "toolRequiresHumanApproval:\(toolName)")
        }
        let baseURL = URL(fileURLWithPath: workspacePath)
        guard !ToolApprovalPolicy.reachesOutsideWorkingDirectory(patterns, baseURL: baseURL) else {
            return .deny(reason: "outsideWorkspaceRequiresHumanApproval")
        }
        // The policy's own rule keeps a file-mutating tool without patterns from
        // being treated as in-workspace: unproven scope must ask a human.
        guard
            ToolApprovalPolicy.approveSafe.automaticReply(
                for: toolName,
                patterns: patterns,
                baseURL: baseURL
            ) != nil
        else {
            return .deny(reason: "missingPatternsRequireHumanApproval:\(toolName)")
        }
        return .approveOnce
    }

    /// Network-capable tools that must never run unattended under live dispatch.
    private static func isNetworkTool(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        return name == "websearch" || name == "webfetch"
            || name.hasSuffix("_websearch") || name.hasSuffix("_webfetch")
    }
}

// MARK: - Refusals and report

/// Typed refusals raised before a live run may start. Every dispatch gate fails closed.
enum TaskDispatchRefusal: LocalizedError, Equatable, Sendable {
    case dispatchDisabled(taskID: UUID)
    case dispatchAlreadyActive(taskID: UUID)
    case taskNotRunning(taskID: UUID, status: TaskStatus)
    case staleAttempt(
        taskID: UUID,
        expectedAttemptID: UUID,
        expectedGeneration: Int,
        actualAttemptID: UUID?,
        actualGeneration: Int?
    )
    case workspaceNotOwned(taskID: UUID, reason: String)
    case workspaceIdentityMismatch(taskID: UUID, expectedWorkspaceID: UUID, actualWorkspaceID: UUID)
    case providerNotEligible(taskID: UUID, missingCapabilities: [String])
    case providerUnavailable(taskID: UUID, reason: String)
    case budgetExhausted(taskID: UUID, reason: String)
    case executeApprovalMissing(taskID: UUID, attemptID: UUID, fingerprint: String)
    case runtimeStartFailed(taskID: UUID, reason: String)

    var errorDescription: String? {
        switch self {
        case .dispatchDisabled(let taskID):
            return "Live dispatch is disabled for task \(taskID): no running port is injected"
        case .dispatchAlreadyActive(let taskID):
            return "Task \(taskID) already has a live run"
        case .taskNotRunning(let taskID, let status):
            return "Task \(taskID) cannot be dispatched from status \(status.rawValue)"
        case .staleAttempt(let taskID, let expectedAttemptID, let expectedGeneration, let actualAttemptID, let actualGeneration):
            return
                "Task \(taskID) active attempt changed: expected \(expectedAttemptID.uuidString)/gen \(expectedGeneration), actual \(actualAttemptID?.uuidString ?? "none")/gen \(actualGeneration.map(String.init) ?? "none")"
        case .workspaceNotOwned(let taskID, let reason):
            return "Task \(taskID) has no owned workspace: \(reason)"
        case .workspaceIdentityMismatch(let taskID, let expectedWorkspaceID, let actualWorkspaceID):
            return
                "Task \(taskID) workspace identity changed: expected \(expectedWorkspaceID.uuidString), actual \(actualWorkspaceID.uuidString)"
        case .providerNotEligible(let taskID, let missingCapabilities):
            return "Task \(taskID) has no eligible runtime: \(missingCapabilities.joined(separator: ", "))"
        case .providerUnavailable(let taskID, let reason):
            return "Task \(taskID) runtime is unavailable: \(reason)"
        case .budgetExhausted(let taskID, let reason):
            return "Task \(taskID) cannot be dispatched: \(reason)"
        case .executeApprovalMissing(let taskID, let attemptID, let fingerprint):
            return
                "Task \(taskID) attempt \(attemptID.uuidString) has no executeRecipe approval for fingerprint \(fingerprint)"
        case .runtimeStartFailed(let taskID, let reason):
            return "Task \(taskID) runtime failed to start: \(reason)"
        }
    }
}

/// Result of one dispatch: the terminal outcome, reported usage, every approval
/// decision the scheduler made, and the completion report the existing path produced.
struct TaskRunDispatchReport: Sendable, Equatable {
    let taskID: UUID
    let attemptID: UUID
    let outcome: AttemptOutcome
    let toolCallCount: Int?
    let approvalDecisions: [TaskRunApprovalDecision]
    let completion: TaskAttemptCompletionReport
}

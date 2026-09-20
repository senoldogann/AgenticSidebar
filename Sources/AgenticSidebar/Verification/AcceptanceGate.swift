import Foundation

/// Explicit reason why completion is denied; a blocked decision always carries at least one.
public enum AcceptanceBlockReason: Sendable, Codable, Equatable {
    /// Completion can only be decided for a task in review.
    case taskNotInReview(status: TaskStatus)
    /// The task does not point at the evaluated attempt.
    case attemptNotCurrent(expected: UUID, actual: UUID?)
    /// The evaluated attempt belongs to a different task.
    case attemptTaskMismatch(expectedTaskID: UUID, actualTaskID: UUID)
    /// No content fingerprint can be verified; nothing may close without one.
    case currentFingerprintUnavailable
    /// Acceptance criteria not marked complete by a human.
    case unmetCriteria(ids: [UUID])
    /// A required verification step has no evidence for this task.
    case missingRequiredStep(name: String)
    /// The latest evidence for a required step did not pass.
    case requiredStepNotPassed(name: String, status: VerificationEvidenceStatus)
    /// Required evidence was produced by a recipe whose semantics are unknown.
    case requiredStepUnknownRecipeVersion(name: String, version: Int?)
    /// Passed evidence records no workspace fingerprint.
    case requiredStepFingerprintMissing(name: String)
    /// Passed evidence was recorded on a different revision than the current one.
    case requiredStepFingerprintMismatch(name: String, recorded: String, current: String)
    /// Open findings in the blocking severity band still apply to this attempt.
    case openBlockingFindings(ids: [UUID])
    /// An `accept` approval exists but binds a different attempt.
    case acceptanceApprovalAttemptMismatch(expected: UUID, actual: UUID)
    /// An `accept` approval exists but binds different content.
    case acceptanceApprovalFingerprintMismatch(expected: String, actual: String)
}

/// Outcome of the completion gate; never a bare boolean without reasons.
public enum AcceptanceDecision: Sendable, Equatable {
    /// Objective gates passed; an explicit human `accept` approval is still required.
    case readyForHumanReview
    /// At least one explicit reason denies completion.
    case blocked(reasons: [AcceptanceBlockReason])
    /// Every gate passed and a matching `accept` approval authorizes completion.
    case accepted
}

/// Deterministic, side-effect-free completion gate.
///
/// Only actual verification evidence can satisfy the required steps: text claiming success
/// is never read. Evidence counts only when it is bound to this task, passed, was produced
/// by a known recipe version and was recorded on the current fingerprint. A human `accept`
/// approval must additionally bind the same attempt and exact content; changed content
/// revokes it. Only `.accept` authorizes `done`; merge, push and discardWorkspace are
/// separate future approvals.
public enum AcceptanceGate {
    /// Required verification steps produced by the SwiftPM resolver.
    /// `format` is the lint step; an absent, skipped or failed lint result denies completion.
    public static let requiredStepNames: [String] = ["build", "test", "format"]

    public static func evaluate(
        task: CodingTask,
        attempt: TaskAttempt,
        evidence: [VerificationEvidence],
        findings: [ReviewFinding],
        approvals: [TaskApproval],
        currentFingerprint: String
    ) -> AcceptanceDecision {
        var reasons: [AcceptanceBlockReason] = []

        if task.status != .review {
            reasons.append(.taskNotInReview(status: task.status))
        }
        if attempt.taskID != task.id {
            reasons.append(.attemptTaskMismatch(expectedTaskID: task.id, actualTaskID: attempt.taskID))
        }
        if task.currentAttemptID != attempt.id {
            reasons.append(.attemptNotCurrent(expected: attempt.id, actual: task.currentAttemptID))
        }
        if currentFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append(.currentFingerprintUnavailable)
        }

        let unmetCriteria = task.criteria.filter { !$0.isCompleted }.map(\.id)
        if !unmetCriteria.isEmpty {
            reasons.append(.unmetCriteria(ids: unmetCriteria))
        }

        let blockingFindings =
            findings
            .filter { $0.taskID == task.id && $0.isOpen && $0.severity.blocksAcceptance && $0.applies(toAttempt: attempt.id) }
            .map(\.id)
        if !blockingFindings.isEmpty {
            reasons.append(.openBlockingFindings(ids: blockingFindings))
        }

        for stepName in requiredStepNames {
            let reason = stepReason(
                name: stepName,
                taskID: task.id,
                evidence: evidence,
                currentFingerprint: currentFingerprint
            )
            if let reason {
                reasons.append(reason)
            }
        }

        if !reasons.isEmpty {
            return .blocked(reasons: reasons)
        }

        let acceptApprovals = approvals.filter { $0.taskID == task.id && $0.action == .accept }
        let matching = acceptApprovals.contains { $0.attemptID == attempt.id && $0.fingerprint == currentFingerprint }
        if matching {
            return .accepted
        }
        if acceptApprovals.isEmpty {
            return .readyForHumanReview
        }

        let approvalReasons = acceptApprovals.flatMap { approval -> [AcceptanceBlockReason] in
            var reasons: [AcceptanceBlockReason] = []
            if approval.attemptID != attempt.id {
                reasons.append(.acceptanceApprovalAttemptMismatch(expected: attempt.id, actual: approval.attemptID))
            }
            if approval.fingerprint != currentFingerprint {
                reasons.append(
                    .acceptanceApprovalFingerprintMismatch(expected: currentFingerprint, actual: approval.fingerprint)
                )
            }
            return reasons
        }
        return .blocked(reasons: deduplicated(approvalReasons))
    }

    /// The blocking reason for one required step, or nil when its latest evidence satisfies it.
    ///
    /// The newest entry for the task and step wins: a later failure or skip supersedes an
    /// earlier pass instead of being hidden by it.
    private static func stepReason(
        name: String,
        taskID: UUID,
        evidence: [VerificationEvidence],
        currentFingerprint: String
    ) -> AcceptanceBlockReason? {
        let stepEvidence = evidence.filter { $0.taskID == taskID && $0.stepName == name }
        guard let latest = stepEvidence.sorted(by: evidenceOrder).last else {
            return .missingRequiredStep(name: name)
        }
        guard latest.status == .passed else {
            return .requiredStepNotPassed(name: name, status: latest.status)
        }
        guard let version = latest.recipeVersion, version == VerificationRecipe.currentVersion else {
            return .requiredStepUnknownRecipeVersion(name: name, version: latest.recipeVersion)
        }
        guard let recordedFingerprint = latest.workspaceFingerprint else {
            return .requiredStepFingerprintMissing(name: name)
        }
        guard recordedFingerprint == currentFingerprint else {
            return .requiredStepFingerprintMismatch(name: name, recorded: recordedFingerprint, current: currentFingerprint)
        }
        return nil
    }

    /// Deterministic ordering: oldest first by recorded time, identity as the tie-break.
    private static func evidenceOrder(_ lhs: VerificationEvidence, _ rhs: VerificationEvidence) -> Bool {
        if lhs.recordedAt != rhs.recordedAt {
            return lhs.recordedAt < rhs.recordedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func deduplicated(_ reasons: [AcceptanceBlockReason]) -> [AcceptanceBlockReason] {
        var seen: [AcceptanceBlockReason] = []
        for reason in reasons where !seen.contains(reason) {
            seen.append(reason)
        }
        return seen
    }
}

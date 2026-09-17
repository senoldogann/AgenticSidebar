import Foundation

/// Whether the assistant may change files, or has to agree a plan first.
///
/// Build is the agentic default. Plan mode keeps the assistant read-only: it is
/// asked to answer with a single `plan` block, which the transcript renders as a
/// document rather than as chat prose, and to stop there. Nothing is built until
/// the user approves that plan, which is what the transcript's approval
/// affordance switches the session back to Build mode for.
///
/// The instruction travels with the request exactly like `ResponseSpeedMode`
/// does, so both adapters gain the mode without any new protocol surface.
enum AgentMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case build
    case plan
    case review
    case exam

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .build: "Build"
        case .plan: "Plan"
        case .review: "Review"
        case .exam: "Exam"
        }
    }

    var symbolName: String {
        switch self {
        case .build: "hammer.fill"
        case .plan: "list.checklist"
        case .review: "checkmark.shield.fill"
        case .exam: "graduationcap.fill"
        }
    }

    var helpText: String {
        switch self {
        case .build:
            "Changes files and runs tools to finish the task"
        case .plan:
            "Investigates read-only and proposes a plan; nothing changes until you approve it"
        case .review:
            "Reviews code against security, bug, and quality standards, then proposes a plan"
        case .exam:
            "Solves exam, test, and quiz questions with direct answers, mathematical derivations, and code"
        }
    }

    /// The fence language that marks a plan document inside a reply.
    ///
    /// Shared with the markdown renderer, which turns that fence into a document
    /// card instead of a code block, so the model only has to emit ```plan.
    static let planFenceLanguage = "plan"

    /// `nil` for the mode that needs no instruction — the provider's own default
    /// behaviour is already the build workflow.
    var instruction: String? {
        switch self {
        case .build:
            nil
        case .plan:
            """
            PLAN MODE: Do not create, edit, delete or move any file, and do not run \
            any command that changes state. Investigate with read-only tools first, \
            then reply with exactly one fenced ```\(Self.planFenceLanguage) block \
            holding the complete implementation plan as Markdown: the goal, the \
            ordered steps, every file to be touched and what changes in it, the \
            risks, and how the result will be verified. Write nothing outside that \
            block — no preamble and no closing summary. Do not start implementing: \
            the user approves the plan first.
            """
        case .review:
            """
            REVIEW MODE (Alibaba Open Code Review standard): \
            Perform a thorough, read-only code review on the repository, target project, or Git diff. \
            Do not create, edit, or delete any files, and do not run destructive commands. \
            Inspect the code using read-only tools and skills. \
            Analyze for: \
            1. Correctness & logic bugs \
            2. Null Pointer / Optional safety \
            3. Thread safety, race conditions & concurrency issues \
            4. Security vulnerabilities (injection, XSS, insecure deserialization, credentials) \
            5. Performance bottlenecks \
            6. Code style & maintainability \
            Format your review findings grouped by severity (Critical, High, Medium, Low) with exact file and line references. \
            Conclude with a prioritized remediation plan in a fenced ```\(Self.planFenceLanguage) block so the user can review and approve fixes.
            """
        case .exam:
            """
            EXAM & TEST SOLVER MODE: \
            You are an expert exam, test, and quiz solving assistant with rigorous domain mastery across mathematics, science, engineering, programming, logic, and general subjects. \
            When answering any question (from an image, screenshot, copied text, or problem description): \
            1. DIRECT & DEFINITIVE ANSWER FIRST: \
            State the clear, unambiguous final answer at the very beginning (e.g. "**Correct Answer: C**" or "**Final Answer: 42**"). \
            2. STEP-BY-STEP SOLUTION & DERIVATION: \
            Provide a structured, step-by-step mathematical proof, derivation, or reasoning explaining why this answer is correct. \
            For multiple choice questions, explain why the chosen option is correct and why tricky alternative options are incorrect. \
            3. MATHEMATICAL NOTATION & EQUATIONS: \
            Format mathematical equations and formulas clearly using standard Unicode symbols (e.g., √, ∛, π, ∑, ∫, ±, ≠, ≤, ≥, ≈, ×, ÷, ·, ∞, ∈, ∉, ⊂, ∪, ∩, ∂, ∇, ², ³, ⁿ, ₁, ₂, ½) alongside clear LaTeX expressions ($...$ or $$...$$). \
            4. CODE AND ALGORITHMS: \
            Write all code, SQL, or algorithmic solutions in fenced code blocks with explicit language identifiers (e.g., ```python, ```swift, ```sql). \
            5. THOROUGHNESS & PRECISION: \
            Double-check arithmetic, signs, units, edge cases, and wording before concluding.
            """
        }
    }

    /// Combined with the speed instruction — and with whatever the user tagged
    /// on this turn — for providers that take one system instruction rather than
    /// a prompt prefix.
    func instructions(
        speedMode: ResponseSpeedMode,
        extensionContext: String? = nil
    ) -> String? {
        let parts = [instruction, speedMode.instruction, extensionContext]
            .compactMap { $0 }

        guard !parts.isEmpty else {
            return nil
        }

        return parts.joined(separator: "\n\n")
    }
}

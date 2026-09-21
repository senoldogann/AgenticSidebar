import Foundation

/// How the assistant should trade thoroughness for latency.
///
/// Normal mode is the full agentic workflow. Fast mode tells the model to stay
/// on the shortest path to the answer: no plan narration, no exploration, and
/// tool use only when the task cannot be answered without it.
enum ResponseSpeedMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case normal
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: "brain"
        case .fast: "bolt.fill"
        }
    }

    var helpText: String {
        switch self {
        case .normal:
            "Full agentic workflow: explores, uses tools, and checks its work"
        case .fast:
            "Answers immediately with minimal exploration and no filler"
        }
    }

    /// `nil` means the provider's own default behavior.
    var instruction: String? {
        switch self {
        case .normal:
            nil
        case .fast:
            """
            FAST MODE: Prioritize immediate time-to-first-token and maximum velocity without compromising code correctness or engineering quality.
            - Deliver the same thorough, high-caliber, and accurate solution as normal mode, with zero preamble, no greeting, and no filler summary.
            - Start outputting the concrete solution and code changes directly.
            - When tools are required, execute them decisively and concisely: batch independent tool calls, do not narrate the plan, and do not ask clarifying questions when the request is actionable.
            """
        }
    }
}

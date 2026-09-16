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
            FAST MODE: Answer immediately with the final result. Do not greet, do not \
            restate the request, do not describe your plan, and do not summarize at the \
            end. Use tools only when the answer truly depends on them; otherwise answer \
            directly from what you already know. Keep the reply as short as the question \
            allows.
            """
        }
    }
}

import Foundation

enum SessionPhase: Equatable, Sendable {
    case idle
    case thinking
    case runningTool(String)
    case waiting
    case completed
}

struct SessionPresentationState: Equatable, Sendable {
    var phase: SessionPhase
    var startedAt: Date?
    var completedAt: Date?

    init(
        phase: SessionPhase,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            "Idle"
        case .thinking:
            "Thinking"
        case let .runningTool(toolName):
            "Running \(toolName)"
        case .waiting:
            "Waiting"
        case .completed:
            "Completed"
        }
    }

    var symbolName: String {
        switch phase {
        case .idle:
            "circle"
        case .thinking:
            "brain"
        case .runningTool:
            "wrench.and.screwdriver"
        case .waiting:
            "hourglass"
        case .completed:
            "checkmark.circle.fill"
        }
    }

    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else {
            return 0
        }

        let effectiveEnd = completedAt.map { min($0, now) } ?? now
        return max(0, effectiveEnd.timeIntervalSince(startedAt))
    }
}

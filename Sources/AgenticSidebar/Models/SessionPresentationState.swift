import Foundation

enum SessionPhase: Equatable, Sendable {
    case idle
    case thinking
    case runningTool(String)
    case waiting
    case cancelling
    case cancelled
    case completed
    case failed
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

    init(agentSessionState: AgentSessionState) {
        switch agentSessionState.status {
        case .idle:
            phase = .idle
        case .streaming:
            phase = .thinking
        case let .runningTool(toolName):
            phase = .runningTool(toolName)
        case .waiting:
            phase = .waiting
        case .cancelling:
            phase = .cancelling
        case .completed:
            phase = .completed
        case .cancelled:
            phase = .cancelled
        case .failed:
            phase = .failed
        }

        startedAt = agentSessionState.startedAt
        completedAt = agentSessionState.completedAt
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
        case .cancelling:
            "Cancelling"
        case .cancelled:
            "Cancelled"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
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
        case .cancelling:
            "stop.circle"
        case .cancelled:
            "xmark.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle"
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

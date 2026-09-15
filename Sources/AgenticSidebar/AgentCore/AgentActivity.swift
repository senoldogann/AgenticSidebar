import Foundation

enum AgentActivityPhase: Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

struct AgentActivity: Identifiable, Equatable, Sendable {
    let id: ProviderActivityID
    let kind: ProviderActivityKind
    var phase: AgentActivityPhase
}

struct AgentTurnActivityGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let anchorMessageID: UUID
    var activities: [AgentActivity]
}

import Foundation

/// One row of the session list.
///
/// Deliberately narrow: it carries only values that change on turn boundaries,
/// so a streaming background session does not re-render the sidebar 25 times a
/// second.
struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let isBusy: Bool
    let status: AgentSessionStatus
    let completedAt: Date?
    /// Creation date of the newest message. Restored conversations carry no
    /// `completedAt` (a turn never survives relaunch), so the sidebar needs a
    /// real timestamp to show instead of claiming the session is empty.
    let lastMessageAt: Date?
}

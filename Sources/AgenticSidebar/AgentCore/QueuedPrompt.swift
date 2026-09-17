import Foundation

/// A message waiting for its turn.
///
/// Everything the turn will need is captured when the user sends it — including
/// the mode and speed that were selected at that moment — so a prompt cannot be
/// altered by the controls the user touches while it waits.
struct QueuedPrompt: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let text: String
    let attachmentPaths: [String]
    /// Extensions tagged in the composer when this prompt was written.
    let extensionTags: [ExtensionTag]
    let speedMode: ResponseSpeedMode
    let mode: AgentMode

    init(
        id: UUID = UUID(),
        text: String,
        attachmentPaths: [String] = [],
        extensionTags: [ExtensionTag] = [],
        speedMode: ResponseSpeedMode = .normal,
        mode: AgentMode = .build
    ) {
        self.id = id
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.extensionTags = extensionTags
        self.speedMode = speedMode
        self.mode = mode
    }
}

/// What happened to a prompt the user handed over.
enum PromptAcceptance: Equatable, Sendable {
    /// The turn started immediately.
    case started
    /// A turn was already running, so the prompt was appended to the queue.
    case queued
    /// Nothing could accept it (empty text, missing configuration, or a session
    /// that cannot run a turn at all).
    case rejected

    var wasAccepted: Bool {
        self != .rejected
    }
}

import Foundation

/// The lookups a transcript row needs, built once per change instead of once per
/// frame.
///
/// In the detail view, row-level lookups are expensive to derive inside `body`:
/// - The prompt rail's titles (trimming and splitting user prompts)
/// - The activity group that belongs to a message (groups anchored to message ID)
/// - Which assistant messages are the final message of their turn (for copy/timestamp display)
/// - Which user messages show a turn header
/// - Message IDs belonging to the active turn (for activity active state check)
///
/// Precomputing all of these once per structural change in a single O(N) pass
/// reduces row evaluations in `LazyVStack` to O(1) dictionary and set lookups.
struct TranscriptIndex {
    let promptItems: [PromptNavigatorRail.Item]
    let groupsByAnchor: [UUID: AgentTurnActivityGroup]
    let lastAssistantMessageIDs: Set<UUID>
    let turnHeaderUserMessageIDs: Set<UUID>
    let lastUserMessageID: UUID?
    let lastMessageID: UUID?
    let activeTurnMessageIDs: Set<UUID>

    struct Metadata {
        let lastAssistantMessageIDs: Set<UUID>
        let turnHeaderUserMessageIDs: Set<UUID>
        let lastUserMessageID: UUID?
        let lastMessageID: UUID?
        let activeTurnMessageIDs: Set<UUID>
    }

    /// Derives row lookup metadata across the conversation transcript in a single O(N) pass.
    static func deriveMetadata(
        messages: [ChatMessage],
        groupsByAnchor: [UUID: AgentTurnActivityGroup]
    ) -> Metadata {
        var lastAssistantIDs = Set<UUID>()
        var foundAssistantInCurrentTurn = false

        for message in messages.reversed() {
            if message.role == .user {
                foundAssistantInCurrentTurn = false
            } else if message.role == .assistant {
                let isNonEmpty = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isNonEmpty && !foundAssistantInCurrentTurn {
                    lastAssistantIDs.insert(message.id)
                    foundAssistantInCurrentTurn = true
                }
            }
        }

        let lastUserID = messages.last(where: { $0.role == .user })?.id
        let lastMsgID = messages.last?.id

        var turnHeaderUserIDs = Set<UUID>()
        for i in 0..<messages.count {
            let msg = messages[i]
            guard msg.role == .user else { continue }
            if i + 1 < messages.count && messages[i + 1].role == .assistant {
                turnHeaderUserIDs.insert(msg.id)
            } else if groupsByAnchor[msg.id] != nil {
                turnHeaderUserIDs.insert(msg.id)
            }
        }

        let activeTurnIDs: Set<UUID>
        if let activeUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            activeTurnIDs = Set(messages[activeUserIndex...].map(\.id))
        } else {
            activeTurnIDs = []
        }

        return Metadata(
            lastAssistantMessageIDs: lastAssistantIDs,
            turnHeaderUserMessageIDs: turnHeaderUserIDs,
            lastUserMessageID: lastUserID,
            lastMessageID: lastMsgID,
            activeTurnMessageIDs: activeTurnIDs
        )
    }

    /// One entry per prompt the user sent, oldest first: the rail maps the
    /// conversation's questions, not the answers.
    static func promptItems(
        for messages: [ChatMessage],
        maximumPromptCount: Int
    ) -> [PromptNavigatorRail.Item] {
        messages
            .filter { $0.role == .user }
            .suffix(maximumPromptCount)
            .map { message in
                let prompt = message.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return PromptNavigatorRail.Item(
                    id: message.id,
                    title: TranscriptIndex.railTitle(for: prompt),
                    prompt: prompt
                )
            }
    }

    /// The activity group anchored to each message, so a row's timeline is a
    /// lookup rather than a scan of every turn in the conversation.
    static func groupsByAnchor(
        _ activityGroups: [AgentTurnActivityGroup]
    ) -> [UUID: AgentTurnActivityGroup] {
        activityGroups.reduce(into: [:]) { result, group in
            // The first group wins, which matches the linear search this replaces.
            if result[group.anchorMessageID] == nil {
                result[group.anchorMessageID] = group
            }
        }
    }

    func activityGroup(after messageID: UUID) -> AgentTurnActivityGroup? {
        groupsByAnchor[messageID]
    }

    /// The first line of a prompt, short enough to label a navigation bar.
    static func railTitle(for prompt: String) -> String {
        let firstLine =
            prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "Attachment"
        }

        return trimmed.count <= 60
            ? trimmed
            : String(trimmed.prefix(59)) + "…"
    }
}

/// Rebuilds each half of the index only when the inputs it is derived from have
/// moved.
///
/// Anahtarlar sabit zamanda kurulur: akan asistan metni her karede büyürken
/// bütün transkript ya da aktivite geçmişi yeniden dolaşılmaz. Yapısal bir
/// değişiklik olduğunda asıl O(N) indeks yalnız bir kez yeniden kurulur.
@MainActor
final class TranscriptIndexCache {
    private var promptItems: [PromptNavigatorRail.Item] = []
    private var groupsByAnchor: [UUID: AgentTurnActivityGroup] = [:]
    private var lastAssistantMessageIDs: Set<UUID> = []
    private var turnHeaderUserMessageIDs: Set<UUID> = []
    private var lastUserMessageID: UUID?
    private var lastMessageID: UUID?
    private var activeTurnMessageIDs: Set<UUID> = []

    private var promptKey: PromptKey?
    private var groupKey: GroupKey?

    /// How many times each half has been rebuilt. The tests use these to prove
    /// that streaming text does not trigger a rebuild.
    private(set) var promptRebuilds = 0
    private(set) var groupRebuilds = 0

    func index(
        messages: [ChatMessage],
        activityGroups: [AgentTurnActivityGroup],
        maximumPromptCount: Int,
        activityRevision: Int
    ) -> TranscriptIndex {
        let newPromptKey = PromptKey(messages: messages, maximumPromptCount: maximumPromptCount)
        let newGroupKey = GroupKey(groups: activityGroups, activityRevision: activityRevision)

        var didRebuildPrompt = false
        var didRebuildGroup = false

        if newPromptKey != promptKey {
            promptKey = newPromptKey
            promptRebuilds += 1
            promptItems = TranscriptIndex.promptItems(
                for: messages,
                maximumPromptCount: maximumPromptCount
            )
            didRebuildPrompt = true
        }

        if newGroupKey != groupKey {
            groupKey = newGroupKey
            groupRebuilds += 1
            groupsByAnchor = TranscriptIndex.groupsByAnchor(activityGroups)
            didRebuildGroup = true
        }

        if didRebuildPrompt || didRebuildGroup {
            let metadata = TranscriptIndex.deriveMetadata(
                messages: messages,
                groupsByAnchor: groupsByAnchor
            )
            lastAssistantMessageIDs = metadata.lastAssistantMessageIDs
            turnHeaderUserMessageIDs = metadata.turnHeaderUserMessageIDs
            lastUserMessageID = metadata.lastUserMessageID
            lastMessageID = metadata.lastMessageID
            activeTurnMessageIDs = metadata.activeTurnMessageIDs
        }

        return TranscriptIndex(
            promptItems: promptItems,
            groupsByAnchor: groupsByAnchor,
            lastAssistantMessageIDs: lastAssistantMessageIDs,
            turnHeaderUserMessageIDs: turnHeaderUserMessageIDs,
            lastUserMessageID: lastUserMessageID,
            lastMessageID: lastMessageID,
            activeTurnMessageIDs: activeTurnMessageIDs
        )
    }

    /// Prompt titles and turn metadata depend on messages.
    /// Assistant text streaming does NOT change user messages, message counts, or IDs.
    private struct PromptKey: Equatable {
        let messageCount: Int
        let lastMessageID: UUID?
        let maximumPromptCount: Int

        init(messages: [ChatMessage], maximumPromptCount: Int) {
            messageCount = messages.count
            lastMessageID = messages.last?.id
            self.maximumPromptCount = maximumPromptCount
        }
    }

    /// The group dictionary changes when a turn is added, when one of its
    /// activities changes phase or count — or when an activity's content is
    /// rewritten while it runs (a live subagent step, a growing tool output).
    /// The revision counter is what makes the last case visible; without it the
    /// row kept rendering the cached copy and the card froze until the phase
    /// changed.
    private struct GroupKey: Equatable {
        let turnCount: Int
        let lastTurnID: UUID?
        let activityRevision: Int

        init(groups: [AgentTurnActivityGroup], activityRevision: Int) {
            turnCount = groups.count
            lastTurnID = groups.last?.id
            self.activityRevision = activityRevision
        }
    }
}

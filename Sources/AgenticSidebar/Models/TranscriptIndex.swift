import Foundation

/// The lookups a transcript row needs, built once per change instead of once per
/// frame.
///
/// Two things in the detail view are expensive to derive and were being derived
/// inside `body`: the prompt rail's titles (a trim and a split of every prompt
/// text in the conversation) and the activity group that belongs to a message (a
/// linear scan per row). During streaming `body` runs about twenty-five times a
/// second, so both were paid again and again over a transcript that had not
/// changed at all.
struct TranscriptIndex {
    let promptItems: [PromptNavigatorRail.Item]
    let groupsByAnchor: [UUID: AgentTurnActivityGroup]

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
        let firstLine = prompt
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
/// The keys are deliberately cheap — counts, identifiers and the last activity's
/// phase — so that a frame of streaming that changes nothing the index depends on
/// does not rebuild it. Assistant text grows every frame; the index does not care
/// about assistant text at all.
@MainActor
final class TranscriptIndexCache {
    private var promptItems: [PromptNavigatorRail.Item] = []
    private var groupsByAnchor: [UUID: AgentTurnActivityGroup] = [:]
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

        if newPromptKey != promptKey {
            promptKey = newPromptKey
            promptRebuilds += 1
            promptItems = TranscriptIndex.promptItems(
                for: messages,
                maximumPromptCount: maximumPromptCount
            )
        }

        if newGroupKey != groupKey {
            groupKey = newGroupKey
            groupRebuilds += 1
            groupsByAnchor = TranscriptIndex.groupsByAnchor(activityGroups)
        }

        return TranscriptIndex(
            promptItems: promptItems,
            groupsByAnchor: groupsByAnchor
        )
    }

    /// Prompt titles depend on the user's messages, which do not stream.
    private struct PromptKey: Equatable {
        let userMessageCount: Int
        let lastUserMessageID: UUID?
        let lastUserMessageLength: Int
        let maximumPromptCount: Int

        init(messages: [ChatMessage], maximumPromptCount: Int) {
            var count = 0
            var lastID: UUID?
            var lastLength = 0

            for message in messages where message.role == .user {
                count += 1
                lastID = message.id
                lastLength = message.text.count
            }

            userMessageCount = count
            lastUserMessageID = lastID
            lastUserMessageLength = lastLength
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
        let totalActivityCount: Int
        let runningCount: Int
        let lastPhase: AgentActivityPhase?
        let activityRevision: Int

        init(groups: [AgentTurnActivityGroup], activityRevision: Int) {
            turnCount = groups.count
            lastTurnID = groups.last?.id
            var total = 0
            var running = 0
            for group in groups {
                total += group.activities.count
                for activity in group.activities where activity.phase == .running {
                    running += 1
                }
            }
            totalActivityCount = total
            runningCount = running
            lastPhase = groups.last?.activities.last?.phase
            self.activityRevision = activityRevision
        }
    }
}

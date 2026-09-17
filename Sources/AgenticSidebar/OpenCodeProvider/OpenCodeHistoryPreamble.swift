import Foundation

/// The shared context a fresh backend session starts without.
///
/// The transcript on screen survives a relaunch (it is the archive), but the
/// OpenCode server keeps the conversation inside its own session, and that
/// session does not survive one: the app stops the server on quit, and the
/// runtime's remote-session mapping is in-memory only. The next turn after such
/// a restart submits only the newest user message, so the agent answers with no
/// memory of anything above it — while the user looks at a full transcript.
///
/// The fix is to say what happened, once, in the first turn of a fresh backend
/// session: the earlier turns travel as quoted history inside that prompt, the
/// model reads them as context, and no tool is re-run. Later turns need nothing
/// because the backend session holds them from then on.
enum OpenCodeHistoryPreamble {
    /// Character budget matching TranscriptBudget to ensure conversations
    /// preserve full context across server reconnects and restarts.
    static let maximumCharacters = 96_000

    /// Onarım bloğunun sınırları.
    static let openingMarker = "[Conversation history restored for a new backend session. Treat the following as shared context and continue from the new message below. Do not re-run any tools mentioned here.]"
    static let closingMarker = "[End of restored history.]"

    /// Taşınan metinde ayırıcı yerine geçen işaret.
    private static let neutralizedMarker = "[…]"

    /// Quoted history for the first turn of a fresh backend session, or `nil`
    /// when there is nothing worth restoring (a first turn, or only empty
    /// messages before it).
    static func make(
        from messages: [ChatMessage],
        activityGroups: [AgentTurnActivityGroup] = [],
        newMessageID: UUID,
        maximumCharacters: Int = OpenCodeHistoryPreamble.maximumCharacters
    ) -> String? {
        // The newest turn is submitted as the prompt itself; only what came
        // before it is history.
        let prior = messages.filter { $0.id != newMessageID }
        guard !prior.isEmpty else {
            return nil
        }

        // Map anchor message ID to activity summaries
        var activitySummaryByAnchor: [UUID: String] = [:]
        for group in activityGroups {
            let summaries = group.activities.compactMap { activity -> String? in
                guard activity.kind != .thinking else { return nil }
                let mark = activity.phase == .completed ? "✓" : (activity.phase == .failed ? "✗" : "•")
                if let title = activity.title, !title.isEmpty {
                    return "\(mark) \(title)"
                } else if let detail = activity.detail, !detail.isEmpty {
                    return "\(mark) \(detail)"
                }
                return nil
            }
            if !summaries.isEmpty {
                activitySummaryByAnchor[group.anchorMessageID] = summaries.joined(separator: "; ")
            }
        }

        // Newest first up to the budget, then back into reading order: what is
        // dropped is the oldest context, which is also what the request budget
        // would have trimmed first.
        var kept: [String] = []
        var used = 0
        for message in prior.reversed() {
            let activityNote = activitySummaryByAnchor[message.id]
            guard let line = historyLine(for: message, activitySummary: activityNote), !line.isEmpty else {
                continue
            }
            guard used + line.count <= maximumCharacters else {
                // A single oversized recent message should not hide older lines
                // that still fit the restore budget.
                continue
            }
            kept.append(line)
            used += line.count
        }

        guard !kept.isEmpty else {
            return nil
        }

        // Ayırıcılar taşınan içerikte geçemez: metnin içinden gelen bir
        // "[End of restored history.]" yanılsaması, modelin tarihçenin bittiğine
        // inanmasına ve arkasındaki satırları yeni bir kullanıcı turu sanmasına
        // yol açabilirdi.
        let history = kept.reversed()
            .map(sanitize)
            .joined(separator: "\n")
        return """
        \(Self.openingMarker)

        \(history)

        \(Self.closingMarker)
        """
    }

    /// Taşınan satırdaki ayırıcıları etkisizleştirir.
    private static func sanitize(_ line: String) -> String {
        line
            .replacingOccurrences(of: closingMarker, with: neutralizedMarker)
            .replacingOccurrences(of: openingMarker, with: neutralizedMarker)
    }

    private static func historyLine(
        for message: ChatMessage,
        activitySummary: String? = nil
    ) -> String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let body: String
        if text.isEmpty {
            if let activitySummary, !activitySummary.isEmpty {
                body = "(executed: \(activitySummary))"
            } else if !message.attachmentPaths.isEmpty {
                body = "(no text)"
            } else {
                return nil
            }
        } else {
            if let activitySummary, !activitySummary.isEmpty {
                body = "\(text)\n(executed: \(activitySummary))"
            } else {
                body = text
            }
        }

        let speaker = message.role == .user ? "User" : "Assistant"

        var annotations: [String] = []
        if !message.extensionTags.isEmpty {
            let tagDescriptions = message.extensionTags.map { "\($0.kind.displayName): \($0.name)" }
            annotations.append("tagged: \(tagDescriptions.joined(separator: ", "))")
        }
        if !message.attachmentPaths.isEmpty {
            let names = message.attachmentPaths
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .filter { !$0.isEmpty }
            if !names.isEmpty {
                annotations.append("attached files: \(names.joined(separator: ", "))")
            }
        }

        if annotations.isEmpty {
            return "\(speaker): \(body)"
        }
        return "\(speaker): \(body) [\(annotations.joined(separator: "; "))]"
    }
}

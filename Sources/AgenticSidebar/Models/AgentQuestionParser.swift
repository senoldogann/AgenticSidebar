import Foundation

/// Pure functional parser for extracting interactive questions from tool arguments or text.
enum AgentQuestionParser {
    /// Hızlı yanıt listesi deseni: her çağrıda yeniden derlenmez.
    private static let quickReplyRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:(?:\d+[\.\)]|\-)\s+)(.+)$"#,
        options: []
    )

    /// Attempts to parse an interactive question from tool input properties.
    static func parseFromToolInput(
        toolCallID: String?,
        input: [String: Any]
    ) -> AgentQuestion? {
        let promptCandidates = ["question", "prompt", "title", "message"]
        guard let prompt = promptCandidates.compactMap({ input[$0] as? String }).first,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let options = parseOptions(from: input["options"])
        let allowCustom =
            (input["allowCustomAnswer"] as? Bool)
            ?? (input["allow_custom"] as? Bool)
            ?? (input["allowFreeform"] as? Bool)
            ?? true
        let isMulti =
            (input["isMultiSelect"] as? Bool)
            ?? (input["is_multi_select"] as? Bool)
            ?? (input["multiple"] as? Bool)
            ?? false

        return AgentQuestion(
            id: UUID(),
            toolCallID: toolCallID,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options,
            allowCustomAnswer: allowCustom,
            isMultiSelect: isMulti,
            createdAt: Date(),
            status: .pending
        )
    }

    /// Parses options from either an array of strings or an array of dictionaries.
    static func parseOptions(from raw: Any?) -> [AgentQuestionOption] {
        if let stringArray = raw as? [String] {
            return stringArray.enumerated().map { index, text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isRec = isRecommendedTag(trimmed)
                return AgentQuestionOption(
                    id: "opt_\(index + 1)",
                    label: trimmed,
                    description: nil,
                    isRecommended: isRec
                )
            }
        }

        if let dictArray = raw as? [[String: Any]] {
            return dictArray.enumerated().map { index, dict in
                let label =
                    (dict["label"] as? String)
                    ?? (dict["title"] as? String)
                    ?? (dict["text"] as? String)
                    ?? "Option \(index + 1)"
                let desc = dict["description"] as? String
                let isRec =
                    (dict["isRecommended"] as? Bool)
                    ?? (dict["recommended"] as? Bool)
                    ?? isRecommendedTag(label)
                let id = (dict["id"] as? String) ?? "opt_\(index + 1)"

                return AgentQuestionOption(
                    id: id,
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: desc?.trimmingCharacters(in: .whitespacesAndNewlines),
                    isRecommended: isRec
                )
            }
        }

        return []
    }

    /// Helper to test if a text snippet contains a recommendation badge or label.
    static func isRecommendedTag(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("(recommended)")
            || lower.contains("(önerilen)")
            || lower.contains("(onerilen)")
            || lower.contains("[recommended]")
            || lower.contains("[önerilen]")
            || lower.contains("[onerilen]")
            || lower.contains("(tavsiye)")
    }

    /// Parses numbered or labeled options from markdown text when an assistant asks a question.
    ///
    /// Only a list that ends the message counts: an informational answer that
    /// happens to contain a bullet list mid-text (identities, steps, files)
    /// must not pop up a blocking question card. Lines inside fenced code
    /// blocks are never options.
    static func parseQuickReplyOptions(from text: String) -> [AgentQuestionOption] {
        let lines = text.components(separatedBy: "\n")
        var collected: [AgentQuestionOption] = []
        var lastOptionLineIndex: Int?

        guard let regex = Self.quickReplyRegex else {
            return []
        }

        var insideFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, !trimmed.isEmpty else { continue }
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range),
                let matchRange = Range(match.range(at: 1), in: trimmed)
            {
                let candidate = String(trimmed[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= 2 && candidate.count <= 60 {
                    let optionIndex = collected.count + 1
                    let isRec = isRecommendedTag(candidate)
                    collected.append(
                        AgentQuestionOption(
                            id: "quick_\(optionIndex)",
                            label: candidate,
                            description: nil,
                            isRecommended: isRec
                        )
                    )
                    lastOptionLineIndex = index
                }
            }
        }

        guard collected.count >= 2, collected.count <= 6,
            let lastIndex = lastOptionLineIndex
        else {
            return []
        }

        // Seçeneklerden sonra gelen gerçek içerik (paragraf, kod bloğu), listenin
        // bilgi amaçlı olduğunu gösterir; hızlı yanıt yalnız mesaj listeyle
        // bitiyorsa sunulur.
        let hasTrailingContent = lines[(lastIndex + 1)...].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !hasTrailingContent else {
            return []
        }

        return collected
    }
}

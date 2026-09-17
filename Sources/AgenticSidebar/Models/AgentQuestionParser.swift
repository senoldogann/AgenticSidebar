import Foundation

/// Pure functional parser for extracting interactive questions from tool arguments or text.
enum AgentQuestionParser {
    /// Attempts to parse an interactive question from tool input properties.
    static func parseFromToolInput(
        toolCallID: String?,
        input: [String: Any]
    ) -> AgentQuestion? {
        let promptCandidates = ["question", "prompt", "title", "message"]
        guard let prompt = promptCandidates.compactMap({ input[$0] as? String }).first,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let options = parseOptions(from: input["options"])
        let allowCustom = (input["allowCustomAnswer"] as? Bool)
            ?? (input["allow_custom"] as? Bool)
            ?? (input["allowFreeform"] as? Bool)
            ?? true
        let isMulti = (input["isMultiSelect"] as? Bool)
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
                let isRec = trimmed.lowercased().contains("(recommended)")
                    || trimmed.lowercased().contains("(önerilen)")
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
                let label = (dict["label"] as? String)
                    ?? (dict["title"] as? String)
                    ?? (dict["text"] as? String)
                    ?? "Option \(index + 1)"
                let desc = dict["description"] as? String
                let isRec = (dict["isRecommended"] as? Bool)
                    ?? label.lowercased().contains("(recommended)")
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

    /// Parses numbered or labeled options from markdown text when an assistant asks a question.
    static func parseQuickReplyOptions(from text: String) -> [AgentQuestionOption] {
        let lines = text.components(separatedBy: "\n")
        var collected: [AgentQuestionOption] = []

        let pattern = #"^(?:(?:\d+[\.\)]|\-)\s+)(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range),
               let matchRange = Range(match.range(at: 1), in: trimmed) {
                let candidate = String(trimmed[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= 2 && candidate.count <= 60 {
                    let index = collected.count + 1
                    let isRec = candidate.lowercased().contains("(recommended)")
                        || candidate.lowercased().contains("(önerilen)")
                    collected.append(
                        AgentQuestionOption(
                            id: "quick_\(index)",
                            label: candidate,
                            description: nil,
                            isRecommended: isRec
                        )
                    )
                }
            }
        }

        return (collected.count >= 2 && collected.count <= 6) ? collected : []
    }
}

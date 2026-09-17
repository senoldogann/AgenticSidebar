import Foundation

/// Represents a single selectable choice in an interactive question.
struct AgentQuestionOption: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let label: String
    let description: String?
    let isRecommended: Bool

    init(
        id: String,
        label: String,
        description: String?,
        isRecommended: Bool
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.isRecommended = isRecommended
    }
}

/// The recorded response provided by the user to an interactive question.
struct AgentQuestionAnswer: Equatable, Sendable, Codable {
    let selectedOptionIDs: [String]
    let customText: String?
    let formattedResponse: String

    init(
        selectedOptionIDs: [String],
        customText: String?,
        formattedResponse: String
    ) {
        self.selectedOptionIDs = selectedOptionIDs
        self.customText = customText
        self.formattedResponse = formattedResponse
    }
}

/// The lifecycle state of an interactive agent question.
enum AgentQuestionStatus: Equatable, Sendable, Codable {
    case pending
    case answered(AgentQuestionAnswer)
    case dismissed
}

/// An interactive question presented by the agent to the user during an active session.
struct AgentQuestion: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let toolCallID: String?
    let prompt: String
    let options: [AgentQuestionOption]
    let allowCustomAnswer: Bool
    let isMultiSelect: Bool
    let createdAt: Date
    var status: AgentQuestionStatus

    init(
        id: UUID,
        toolCallID: String?,
        prompt: String,
        options: [AgentQuestionOption],
        allowCustomAnswer: Bool,
        isMultiSelect: Bool,
        createdAt: Date,
        status: AgentQuestionStatus
    ) {
        self.id = id
        self.toolCallID = toolCallID
        self.prompt = prompt
        self.options = options
        self.allowCustomAnswer = allowCustomAnswer
        self.isMultiSelect = isMultiSelect
        self.createdAt = createdAt
        self.status = status
    }

    /// Formats an answer given selected options and optional custom text.
    static func formatAnswer(
        options: [AgentQuestionOption],
        selectedIDs: [String],
        customText: String?
    ) -> AgentQuestionAnswer {
        let chosenLabels: [String]
        if selectedIDs.contains("__all__") || selectedIDs.contains("opt_all") {
            let nonAll = options.filter { $0.id != "__all__" && $0.id != "opt_all" }.map(\.label)
            if nonAll.isEmpty {
                chosenLabels = ["Hepsi (Tümünü uygula)"]
            } else {
                let textSample = nonAll.joined()
                let isTurkish = textSample.range(of: #"[üğşıçöĞÜŞİÇÖ]"#, options: .regularExpression) != nil
                    || textSample.localizedCaseInsensitiveContains("soru")
                    || textSample.localizedCaseInsensitiveContains("hepsi")
                    || textSample.localizedCaseInsensitiveContains("uygula")
                let prefix = isTurkish ? "Hepsi (Tümünü uygula): " : "All of the above: "
                chosenLabels = [prefix + nonAll.joined(separator: ", ")]
            }
        } else {
            chosenLabels = options
                .filter { selectedIDs.contains($0.id) }
                .map(\.label)
        }

        let trimmedCustom = customText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveCustom = (trimmedCustom?.isEmpty == false) ? trimmedCustom : nil

        let summaryParts: [String] = [
            chosenLabels.isEmpty ? nil : chosenLabels.joined(separator: ", "),
            effectiveCustom
        ].compactMap { $0 }

        let response = summaryParts.isEmpty ? "No selection" : summaryParts.joined(separator: " - ")

        return AgentQuestionAnswer(
            selectedOptionIDs: selectedIDs,
            customText: effectiveCustom,
            formattedResponse: response
        )
    }
}

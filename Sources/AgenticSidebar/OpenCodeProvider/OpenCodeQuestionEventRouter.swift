import Foundation

/// A single backend question in a request containing one or more ordered questions.
struct OpenCodeQuestionItem: Equatable, Sendable {
    let prompt: String
    let header: String?
    let options: [AgentQuestionOption]
    let isMultiSelect: Bool
    let allowCustomAnswer: Bool
}

/// The backend owns the request ID; the application must reply once with one
/// array of selected labels for each question, in the original question order.
struct OpenCodeQuestionRequest: Equatable, Sendable {
    let requestID: String
    let remoteSessionID: String
    let toolCallID: String?
    let questions: [OpenCodeQuestionItem]
}

/// Filters the server-wide SSE stream so a question can never be displayed in
/// an unrelated conversation. Children are owned only after a parent `task`
/// part establishes the child session ID, matching the permission routing rule.
struct OpenCodeQuestionEventRouter: Sendable {
    private let sessionID: String
    private var ownedChildSessions: Set<String> = []
    private var unknownQuestions: [String: [OpenCodeQuestionRequest]] = [:]
    private var deliveredIDs: Set<String> = []
    private var deliveredOrder: [String] = []

    private static let maximumUnknownSessions = 8
    private static let maximumUnknownQuestionsPerSession = 16
    private static let maximumDeliveredIDs = 128

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    mutating func consume(line: String) -> [OpenCodeQuestionRequest] {
        guard line.hasPrefix("data:") else { return [] }
        let dataField = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = dataField.data(using: .utf8),
            let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = envelope["type"] as? String,
            let properties = envelope["properties"] as? [String: Any]
        else {
            AppLog.openCode.error("Bozuk soru olayı atlandı: \(line.prefix(120), privacy: .public)")
            return []
        }

        switch type {
        case "question.asked":
            guard let request = Self.parse(properties) else {
                AppLog.openCode.error("question.asked ayrıştırılamadı, atlandı")
                return []
            }
            guard !deliveredIDs.contains(request.requestID) else { return [] }
            if request.remoteSessionID == sessionID || ownedChildSessions.contains(request.remoteSessionID) {
                markDelivered(request.requestID)
                return [request]
            }
            buffer(request)
            return []

        case "message.part.updated":
            guard
                (properties["sessionID"] as? String) == sessionID,
                let part = properties["part"] as? [String: Any],
                (part["type"] as? String) == "tool",
                let tool = part["tool"] as? String,
                // Tek yüklem (`ProviderActivityDescriptor.isSubagentTool`):
                // normalizer hangi aracı delege sayarsa sahiplik de ondan
                // öğrenilir, yoksa delege sorular panele hiç çıkmaz.
                ProviderActivityDescriptor.isSubagentTool(tool),
                let state = part["state"] as? [String: Any],
                let metadata = state["metadata"] as? [String: Any],
                let childID = metadata["sessionId"] as? String,
                !childID.isEmpty,
                childID != sessionID
            else { return [] }

            ownedChildSessions.insert(childID)
            return (unknownQuestions.removeValue(forKey: childID) ?? []).filter { request in
                guard !deliveredIDs.contains(request.requestID) else { return false }
                markDelivered(request.requestID)
                return true
            }

        case "session.idle":
            if (properties["sessionID"] as? String) == sessionID {
                unknownQuestions.removeAll()
                ownedChildSessions.removeAll()
            }
            return []

        default:
            return []
        }
    }

    private mutating func markDelivered(_ id: String) {
        deliveredIDs.insert(id)
        deliveredOrder.append(id)
        if deliveredOrder.count > Self.maximumDeliveredIDs {
            deliveredIDs.remove(deliveredOrder.removeFirst())
        }
    }

    private mutating func buffer(_ request: OpenCodeQuestionRequest) {
        var requests = unknownQuestions[request.remoteSessionID] ?? []
        guard !requests.contains(where: { $0.requestID == request.requestID }) else { return }
        requests.append(request)
        if requests.count > Self.maximumUnknownQuestionsPerSession {
            // Sessiz düşürme yok: atılan soru, modelin yanıt beklediği bir
            // soru olabilir; turun asılı kalması logda iz bırakır.
            AppLog.openCode.error(
                "Dropping an unowned session question under storm pressure; the model may wait for an answer that never arrives"
            )
            requests.removeFirst()
        }
        unknownQuestions[request.remoteSessionID] = requests
        if unknownQuestions.count > Self.maximumUnknownSessions,
            let evicted = unknownQuestions.keys.sorted().first
        {
            AppLog.openCode.error(
                "Evicting buffered questions for an unowned session under storm pressure"
            )
            unknownQuestions.removeValue(forKey: evicted)
        }
    }

    private static func parse(_ properties: [String: Any]) -> OpenCodeQuestionRequest? {
        guard
            let requestID = (properties["id"] as? String) ?? (properties["requestID"] as? String),
            !requestID.isEmpty,
            let sessionID = properties["sessionID"] as? String,
            !sessionID.isEmpty,
            let rawQuestions = properties["questions"] as? [[String: Any]],
            !rawQuestions.isEmpty,
            rawQuestions.count <= 32
        else { return nil }

        var questions: [OpenCodeQuestionItem] = []
        for raw in rawQuestions {
            guard let prompt = raw["question"] as? String,
                !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let choices = raw["options"] as? [[String: Any]]
            else { return nil }
            let options = choices.enumerated().compactMap { index, choice -> AgentQuestionOption? in
                guard let label = choice["label"] as? String, !label.isEmpty else { return nil }
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let isRec =
                    (choice["isRecommended"] as? Bool)
                    ?? (choice["recommended"] as? Bool)
                    ?? AgentQuestionParser.isRecommendedTag(trimmed)
                return AgentQuestionOption(
                    id: "opt_\(index + 1)",
                    label: trimmed,
                    description: choice["description"] as? String,
                    isRecommended: isRec
                )
            }
            guard options.count == choices.count else { return nil }
            questions.append(
                OpenCodeQuestionItem(
                    prompt: prompt,
                    header: raw["header"] as? String,
                    options: options,
                    isMultiSelect: raw["multiple"] as? Bool ?? false,
                    allowCustomAnswer: raw["custom"] as? Bool ?? true
                ))
        }
        let tool = properties["tool"] as? [String: Any]
        return OpenCodeQuestionRequest(
            requestID: requestID,
            remoteSessionID: sessionID,
            toolCallID: tool?["callID"] as? String,
            questions: questions
        )
    }
}

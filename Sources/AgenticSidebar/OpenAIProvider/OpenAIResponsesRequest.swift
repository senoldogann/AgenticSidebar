import Foundation

enum OpenAIResponsesRequest {
    static func make(
        baseURL: URL,
        apiKey: String,
        providerRequest: ProviderRequest
    ) throws -> URLRequest {
        let body = Body(
            model: providerRequest.configuration.modelID.rawValue,
            input: providerRequest.messages.map(InputMessage.init),
            stream: true,
            reasoning: providerRequest.configuration.variantID.map {
                Reasoning(effort: $0.rawValue)
            }
        )

        var request = URLRequest(
            url: baseURL.appendingPathComponent("responses")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private struct Body: Encodable {
        let model: String
        let input: [InputMessage]
        let stream: Bool
        let reasoning: Reasoning?
    }

    private struct InputMessage: Encodable {
        let role: String
        let content: String

        init(message: ChatMessage) {
            switch message.role {
            case .user:
                role = "user"
            case .assistant:
                role = "assistant"
            }
            content = message.text
        }
    }

    private struct Reasoning: Encodable {
        let effort: String
    }
}

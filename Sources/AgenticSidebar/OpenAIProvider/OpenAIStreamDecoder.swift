import Foundation

enum OpenAIStreamDecoder {
    static func decode(line: String) throws -> ProviderEvent? {
        guard line.hasPrefix("data:") else {
            return nil
        }

        let payload = line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)

        guard !payload.isEmpty, payload != "[DONE]" else {
            return nil
        }

        guard let data = payload.data(using: .utf8) else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ProviderRuntimeError.unexpectedResponse
        }

        switch envelope.type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = envelope.delta else {
                throw ProviderRuntimeError.unexpectedResponse
            }
            return .assistantTextDelta(delta)
        case "response.completed":
            return .completed
        case "response.failed", "response.incomplete", "error":
            throw ProviderRuntimeError.unexpectedResponse
        default:
            return nil
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let delta: String?
    }
}

import Foundation

enum OpenAIResponsesRequest {
    static func make(
        baseURL: URL,
        apiKey: String,
        providerRequest: ProviderRequest
    ) throws -> URLRequest {
        // Yuvarlanan özet (`/compact`) en başa: durumsuz sağlayıcı her turda
        // tam listeyi gönderir, düşen ön ekin yerini özet tutar.
        var inputMessages = providerRequest.messages
        if !providerRequest.contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let summaryMessage = ContextCompactor.summaryMessage(providerRequest.contextSummary)
        {
            inputMessages.insert(summaryMessage, at: 0)
        }
        let body = Body(
            model: providerRequest.configuration.modelID.rawValue,
            input: inputMessages.map(InputMessage.init),
            stream: true,
            // The Responses API persists responses by default; this app keeps the
            // transcript local, so storage is explicitly disabled.
            store: false,
            reasoning: {
                if let variant = providerRequest.configuration.variantID {
                    return Reasoning(effort: variant.rawValue)
                } else if providerRequest.speedMode == .fast {
                    return Reasoning(effort: "low")
                }
                return nil
            }(),
            instructions: providerRequest.mode.instructions(
                speedMode: providerRequest.speedMode,
                extensionContext: providerRequest.extensionContext
            )
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
        let store: Bool
        let reasoning: Reasoning?
        /// The selected agent mode and speed ride along as a system-level
        /// instruction; Build mode at Normal speed leaves the field out
        /// entirely, which is the provider's own default workflow.
        let instructions: String?
    }

    /// Mirrors the Responses API `input` item shape: `content` is a plain string
    /// when nothing is attached, and an array of content parts when local images
    /// are inlined as data URLs.
    private struct InputMessage: Encodable {
        let role: String
        let text: String
        let imageDataURLs: [String]

        init(message: ChatMessage) {
            switch message.role {
            case .user:
                role = "user"
            case .assistant:
                role = "assistant"
            }

            var imageDataURLs: [String] = []
            var unsupportedFileNames: [String] = []

            if message.role == .user {
                for path in message.attachmentPaths {
                    if let dataURL = InlineImageData.dataURL(atPath: path) {
                        imageDataURLs.append(dataURL)
                    } else {
                        unsupportedFileNames.append(
                            URL(fileURLWithPath: path).lastPathComponent
                        )
                    }
                }
            }

            self.imageDataURLs = imageDataURLs
            self.text = Self.composedText(
                message.text,
                unsupportedFileNames: unsupportedFileNames
            )
        }

        private enum CodingKeys: String, CodingKey {
            case role
            case content
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)

            guard !imageDataURLs.isEmpty else {
                try container.encode(text, forKey: .content)
                return
            }

            var parts = [Part(type: "input_text", text: text, imageURL: nil)]
            parts.append(
                contentsOf: imageDataURLs.map {
                    Part(type: "input_image", text: nil, imageURL: $0)
                }
            )
            try container.encode(parts, forKey: .content)
        }

        private static func composedText(
            _ text: String,
            unsupportedFileNames: [String]
        ) -> String {
            guard !unsupportedFileNames.isEmpty else {
                return text
            }

            let list =
                unsupportedFileNames
                .map { "- \($0)" }
                .joined(separator: "\n")

            return """
                \(text)

                Attached files that could not be sent to the model (unsupported type or too large):
                \(list)
                """
        }
    }

    private struct Part: Encodable {
        let type: String
        let text: String?
        let imageURL: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(imageURL, forKey: .imageURL)
        }
    }

    private struct Reasoning: Encodable {
        let effort: String
        /// Gösterilebilir akıl yürütme özeti: ham zincir değil, kartta
        /// gösterilen özet deltası. İstenmezse API özet olayı yayınlamaz.
        let summary: String = "auto"
    }
}

/// Turns local image files into inline data URLs the Responses API accepts.
enum InlineImageData {
    static let maximumByteCount = 20 * 1024 * 1024

    static func dataURL(atPath path: String) -> String? {
        guard
            let mimeType = mimeType(forPathExtension: (path as NSString).pathExtension)
        else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: path)
        guard
            let data = try? Data(contentsOf: fileURL),
            !data.isEmpty,
            data.count <= maximumByteCount
        else {
            return nil
        }

        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func mimeType(forPathExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png":
            "image/png"
        case "jpg", "jpeg":
            "image/jpeg"
        case "gif":
            "image/gif"
        case "webp":
            "image/webp"
        case "tif", "tiff":
            "image/tiff"
        case "heic":
            "image/heic"
        default:
            nil
        }
    }
}

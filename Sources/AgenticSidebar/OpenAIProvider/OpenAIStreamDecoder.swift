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
            // Metin taşımayan tek bir olay turu düşürmemeli: eksik bir parça,
            // o ana kadar akmış yanıtı çöpe atmak için yeterli bir gerekçe
            // değil.
            guard let delta = envelope.delta else {
                AppLog.openAI.error(
                    "A \(envelope.type, privacy: .public) event arrived without a delta and was skipped"
                )
                return nil
            }
            return .assistantTextDelta(delta)
        case "response.completed":
            return .completed
        case "response.failed", "response.incomplete", "error":
            throw failure(type: envelope.type, data: data)
        default:
            return nil
        }
    }

    /// Sağlayıcının bildirdiği sebebi korur.
    ///
    /// Her hatayı `unexpectedResponse`'a indirgemek ekrana "bu yanıt
    /// yorumlanamadı" yazdırıyordu; oysa hız sınırı, reddedilen anahtar ve
    /// aşılan bağlam penceresi kullanıcının yapabileceği üç farklı iş demek.
    ///
    /// Ayrıntılar ayrı ve toleranslı bir çözümlemeyle okunur: beklenmedik bir
    /// gövde şekli sebebi genelleştirir, akışı bozmaz.
    private static func failure(type: String, data: Data) -> ProviderRuntimeError {
        let details = (try? JSONDecoder().decode(FailureEnvelope.self, from: data))
            ?? FailureEnvelope.empty

        AppLog.openAI.error(
            "OpenAI stream reported \(type, privacy: .public) with code \(details.code ?? "none", privacy: .public) and reason \(details.reason ?? "none", privacy: .public)"
        )

        let markers = [details.code, details.message, details.reason]
            .compactMap { $0?.lowercased() }

        func mentions(_ needles: [String]) -> Bool {
            markers.contains { marker in
                needles.contains { marker.contains($0) }
            }
        }

        if mentions(["rate_limit", "rate limit", "429"]) {
            return .rateLimited
        }

        if
            mentions([
                "context_length_exceeded",
                "context length",
                "maximum context",
                "context window",
                "reduce the length"
            ])
        {
            return .contextLimitExceeded
        }

        if mentions(["invalid_api_key", "authentication", "unauthorized", "invalid_request_api_key"]) {
            return .authenticationFailure
        }

        if mentions(["server_error", "overloaded", "service_unavailable"]) {
            return .unavailable
        }

        // Adı konmamış her sebep — kesilmiş bir yanıt (`max_output_tokens`) dahil
        // — sağlayıcının kendi sözleriyle gösterilir. Uydurma bir tavsiye
        // ("yeni oturum açın") vermektense sebebi olduğu gibi aktarmak yeğdir.
        ProviderResponseDiagnostics.shared.record(
            provider: "OpenAI",
            statusCode: nil,
            body: "\(type) \(String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")"
        )

        return .unexpectedResponse
    }

    /// Her satır bu dar zarfla çözülür; gövdenin geri kalanı okunmaz, böylece
    /// beklenmedik bir alan bütün akışı düşüremez.
    private struct Envelope: Decodable {
        let type: String
        let delta: String?
    }

    /// Yalnızca hata olaylarında, `try?` ile çözülen ayrıntı zarfı.
    ///
    /// `error` olayında sebep kök nesnededir; `response.failed` olayında
    /// `response.error` altında, `response.incomplete` olayında ise
    /// `response.incomplete_details.reason` alanındadır.
    private struct FailureEnvelope: Decodable {
        let code: String?
        let message: String?
        let reason: String?

        static let empty = FailureEnvelope(code: nil, message: nil, reason: nil)

        init(code: String?, message: String?, reason: String?) {
            self.code = code
            self.message = message
            self.reason = reason
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rootCode = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil
            let rootMessage = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? nil
            let rootError = (try? container.decodeIfPresent(Failure.self, forKey: .error)) ?? nil
            let response = (try? container.decodeIfPresent(ResponseBody.self, forKey: .response)) ?? nil

            code = rootCode ?? rootError?.code ?? response?.error?.code
            message = rootMessage ?? rootError?.message ?? response?.error?.message
            reason = response?.incompleteDetails?.reason
        }

        private enum CodingKeys: String, CodingKey {
            case code
            case message
            case error
            case response
        }
    }

    private struct ResponseBody: Decodable {
        let error: Failure?
        let incompleteDetails: IncompleteDetails?

        private enum CodingKeys: String, CodingKey {
            case error
            case incompleteDetails = "incomplete_details"
        }
    }

    private struct IncompleteDetails: Decodable {
        let reason: String?
    }

    private struct Failure: Decodable {
        let code: String?
        let message: String?
    }
}

import Foundation

enum OpenAIStreamDecoder {
    /// Tek satırdan sıfır ya da daha fazla olay: `response.completed` gövdesi
    /// `response.usage` taşıyorsa önce `.turnUsage`, sonra `.completed` döner.
    /// Kullanım alanı yoksa ya da okunamazsa yalnız `.completed` — akış
    /// istatistik yüzünden bozulmaz.
    static func decode(line: String) throws -> [ProviderEvent] {
        guard line.hasPrefix("data:") else {
            return []
        }

        let payload =
            line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)

        guard !payload.isEmpty, payload != "[DONE]" else {
            return []
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
                return []
            }
            return [.assistantTextDelta(delta)]
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            // Akıl yürütme özeti: ham zincir değil, gösterilebilir özet.
            // Asistan metninden ayrı thinking kanalına akar.
            guard let delta = envelope.delta else {
                AppLog.openAI.error(
                    "A \(envelope.type, privacy: .public) event arrived without a delta and was skipped"
                )
                return []
            }
            return [.thinkingDelta(delta)]
        case "response.completed":
            if let usage = Self.usage(from: data) {
                return [.turnUsage(usage), .completed]
            }
            return [.completed]
        case "response.failed", "response.incomplete", "error":
            throw failure(type: envelope.type, data: data)
        default:
            return []
        }
    }

    /// `response.completed` gövdesindeki `response.usage`:
    /// `{input_tokens, output_tokens, total_tokens}`. Sayılar tam ya da
    /// ondalık gelebilir; eksik ya da geçersizse `nil` (olay üretilmez).
    private static func usage(from data: Data) -> TurnTokenUsage? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = object["response"] as? [String: Any],
            let usage = response["usage"] as? [String: Any],
            let input = Self.tokenCount(usage["input_tokens"]),
            let output = Self.tokenCount(usage["output_tokens"])
        else {
            return nil
        }
        return TurnTokenUsage(inputTokens: input, outputTokens: output)
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number >= 0 ? number : nil
        }
        if let number = value as? Double, number.isFinite, number >= 0 {
            return Int(number)
        }
        if let number = value as? NSNumber {
            let int = number.intValue
            return int >= 0 ? int : nil
        }
        return nil
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
        let details =
            (try? JSONDecoder().decode(FailureEnvelope.self, from: data))
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

        if mentions([
            "context_length_exceeded",
            "context length",
            "maximum context",
            "context window",
            "reduce the length",
        ]) {
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

import Foundation

struct OpenAIProviderRuntime: ProviderRuntime {
    let id = ProviderID("openai")

    private let transport: any OpenAITransport
    private let credentialStore: any CredentialStore
    private let baseURL: URL

    init(
        transport: any OpenAITransport,
        credentialStore: any CredentialStore,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.baseURL = baseURL
    }

    func capabilities() async throws -> ProviderCapabilities {
        let apiKey = try resolveAPIKey()
        let request = makeModelsRequest(apiKey: apiKey)
        let response: OpenAIHTTPResponse

        do {
            response = try await transport.send(request)
        } catch {
            throw ProviderRuntimeError.mapTransportError(error)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw runtimeError(forHTTPStatus: response.statusCode)
        }

        let modelList: ModelList
        do {
            modelList = try JSONDecoder().decode(ModelList.self, from: response.data)
        } catch {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let accessibleIDs = Set(modelList.data.map(\.id))
        return ProviderCapabilities(
            id: id,
            displayName: "OpenAI",
            models: OpenAIModelCatalog.models(accessibleIDs: accessibleIDs)
        )
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        guard request.configuration.providerID == id else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let apiKey = try resolveAPIKey()
        let urlRequest: URLRequest
        do {
            urlRequest = try OpenAIResponsesRequest.make(
                baseURL: baseURL,
                apiKey: apiKey,
                providerRequest: request
            )
        } catch {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let lineStream: OpenAILineStream
        do {
            lineStream = try await transport.stream(urlRequest)
        } catch {
            throw ProviderRuntimeError.mapTransportError(error)
        }

        guard (200..<300).contains(lineStream.statusCode) else {
            let bodyPreview = await Self.bodyPreview(from: lineStream)
            await lineStream.cancel()
            throw runtimeError(
                forHTTPStatus: lineStream.statusCode,
                bodyPreview: bodyPreview
            )
        }

        // Bounded: a fast token stream suspends here instead of buffering the
        // whole response while the session is busy applying it.
        let channel = BoundedChannel<ProviderEvent>(capacity: 128)
        let forwardingTask = Task {
            do {
                for try await line in lineStream.lines {
                    try Task.checkCancellation()

                    for event in try OpenAIStreamDecoder.decode(line: line) {
                        try await channel.send(event)

                        if event == .completed {
                            await lineStream.cancel()
                            await channel.finish()
                            return
                        }
                    }
                }

                await channel.finish()
            } catch is CancellationError {
                await channel.finish(throwing: CancellationError())
            } catch let error as ProviderRuntimeError {
                await channel.finish(throwing: error)
            } catch {
                await channel.finish(throwing: ProviderRuntimeError.transport)
            }
        }

        return ProviderStream(
            events: channel.makeStream(),
            cancellation: {
                forwardingTask.cancel()
                await lineStream.cancel()
                await channel.finish(throwing: CancellationError())
            }
        )
    }

    /// Yan soru (`/btw`): durumsuz sağlayıcıda geçmiş + sorudan kurulu
    /// araçsız tek completion. Kapatılacak oturum yoktur; soru/cevap
    /// transkripte yazılmaz, turn makinesine girilmez.
    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
        guard query.configuration.providerID == id else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let questionMessage = ChatMessage(role: .user, text: query.question)
        let synthetic = ProviderRequest(
            sessionID: UUID(),
            configuration: query.configuration,
            messages: query.historyMessages
                + query.followups.flatMap { $0.messages() }
                + [questionMessage],
            speedMode: query.speedMode,
            mode: query.mode,
            activityGroups: query.activityGroups,
            contextSummary: query.contextSummary
        )
        return try await startStream(for: synthetic)
    }

    /// Error responses carry a short JSON body describing the cause. Reading a
    /// bounded prefix lets the app tell a context-window overflow apart from an
    /// unrelated bad request without ever showing the body to the user.
    static func bodyPreview(from lineStream: OpenAILineStream) async -> String {
        var preview = ""

        do {
            for try await line in lineStream.lines {
                preview += line
                if preview.count >= 4_096 {
                    break
                }
            }
        } catch {
            AppLog.openAI.error(
                "Error-body preview was cut short while reading: \(error.localizedDescription, privacy: .public)"
            )
            return preview
        }

        return preview
    }

    private func resolveAPIKey() throws -> String {
        let storedValue: String?
        do {
            storedValue = try credentialStore.read(.openAIAPIKey)
        } catch {
            throw ProviderRuntimeError.unavailable
        }

        guard
            let apiKey = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            throw ProviderRuntimeError.missingCredential
        }

        return apiKey
    }

    private func makeModelsRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A request that overruns the model context window is reported as a plain
    /// 400, so the body has to be classified to keep the actionable cause.
    static func indicatesContextOverflow(statusCode: Int, bodyPreview: String) -> Bool {
        guard statusCode == 400 || statusCode == 413 else {
            return false
        }

        let lowercased = bodyPreview.lowercased()
        let markers = [
            "context_length_exceeded",
            "context length",
            "maximum context",
            "context window",
            "too many tokens",
            "reduce the length",
        ]

        return markers.contains { lowercased.contains($0) }
    }

    private func runtimeError(
        forHTTPStatus statusCode: Int,
        bodyPreview: String = ""
    ) -> ProviderRuntimeError {
        AppLog.openAI.error("OpenAI HTTP status \(statusCode, privacy: .public)")

        if Self.indicatesContextOverflow(statusCode: statusCode, bodyPreview: bodyPreview) {
            return .contextLimitExceeded
        }

        // Durum eşlemesi ortak politikadır; OpenAI için 401/403 reddedilen bir
        // API anahtarıdır ve kullanıcının Settings'te düzeltebileceği şey odur.
        return .forHTTPStatus(statusCode, unauthorized: .missingCredential)
    }
}

extension OpenAIProviderRuntime {
    fileprivate struct ModelList: Decodable {
        let data: [Model]
    }

    fileprivate struct Model: Decodable {
        let id: String
    }
}

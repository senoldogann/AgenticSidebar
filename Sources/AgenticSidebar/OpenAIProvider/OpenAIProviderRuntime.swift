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
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
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
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
        }

        guard (200..<300).contains(lineStream.statusCode) else {
            await lineStream.cancel()
            throw runtimeError(forHTTPStatus: lineStream.statusCode)
        }

        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let forwardingTask = Task {
            do {
                for try await line in lineStream.lines {
                    try Task.checkCancellation()

                    if let event = try OpenAIStreamDecoder.decode(line: line) {
                        pair.continuation.yield(event)

                        if event == .completed {
                            pair.continuation.finish()
                            return
                        }
                    }
                }

                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish(throwing: CancellationError())
            } catch let error as ProviderRuntimeError {
                pair.continuation.finish(throwing: error)
            } catch {
                pair.continuation.finish(throwing: ProviderRuntimeError.transport)
            }
        }

        return ProviderStream(
            events: pair.stream,
            cancellation: {
                forwardingTask.cancel()
                await lineStream.cancel()
            }
        )
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

    private func runtimeError(forHTTPStatus statusCode: Int) -> ProviderRuntimeError {
        switch statusCode {
        case 401, 403:
            .missingCredential
        case 400..<500, 500..<600:
            .unavailable
        default:
            .unexpectedResponse
        }
    }
}

private extension OpenAIProviderRuntime {
    struct ModelList: Decodable {
        let data: [Model]
    }

    struct Model: Decodable {
        let id: String
    }
}

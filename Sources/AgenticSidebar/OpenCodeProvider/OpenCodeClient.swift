import Foundation

protocol OpenCodeClientProtocol: Sendable {
    func capabilities() async throws -> ProviderCapabilities
    func authMethods() async throws -> [String: [OpenCodeAuthMethod]]
    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws
    func createSession() async throws -> String
    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        text: String
    ) async throws
    func abort(sessionID: String) async throws
    func eventStream() async throws -> OpenCodeLineStream
}

struct OpenCodeClient: OpenCodeClientProtocol {
    private let transport: any OpenCodeTransport
    private let connection: OpenCodeServerConnection

    init(
        transport: any OpenCodeTransport,
        connection: OpenCodeServerConnection
    ) {
        self.transport = transport
        self.connection = connection
    }

    func capabilities() async throws -> ProviderCapabilities {
        let request = makeRequest(pathComponents: ["provider"], method: "GET")
        let response = try await send(request)
        let decoded: OpenCodeProviderListResponse = try decode(
            OpenCodeProviderListResponse.self,
            from: response.data
        )
        let connected = Set(decoded.connected)

        let models = decoded.all
            .filter { connected.contains($0.id) }
            .flatMap { provider in
                provider.models.values.map { model in
                    ProviderModelCapability(
                        id: OpenCodeModelReference(
                            providerID: model.providerID,
                            modelID: model.id
                        ).flattenedID,
                        displayName: "\(provider.name) · \(model.name)",
                        variants: model.variants.map {
                            ProviderVariant(
                                id: ProviderVariantID($0),
                                displayName: Self.variantDisplayName($0)
                            )
                        }
                    )
                }
            }
            .sorted {
                if $0.displayName == $1.displayName {
                    return $0.id.rawValue < $1.id.rawValue
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        return ProviderCapabilities(
            id: ProviderID("opencode"),
            displayName: "OpenCode",
            models: models
        )
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] {
        let request = makeRequest(
            pathComponents: ["provider", "auth"],
            method: "GET"
        )
        let response = try await send(request)
        return try decode(
            [String: [OpenCodeAuthMethod]].self,
            from: response.data
        )
    }

    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws {
        let body = APIAuthBody(
            type: "api",
            key: key,
            metadata: metadata.isEmpty ? nil : metadata
        )
        let request = try makeJSONRequest(
            pathComponents: ["auth", providerID],
            method: "PUT",
            body: body
        )
        _ = try await send(request)
    }

    func createSession() async throws -> String {
        let request = try makeJSONRequest(
            pathComponents: ["session"],
            method: "POST",
            body: EmptyBody()
        )
        let response = try await send(request)
        let session: SessionResponse = try decode(
            SessionResponse.self,
            from: response.data
        )
        return session.id
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        text: String
    ) async throws {
        let request = try makeJSONRequest(
            pathComponents: ["session", sessionID, "prompt_async"],
            method: "POST",
            body: PromptBody(
                model: PromptModel(
                    providerID: model.providerID,
                    modelID: model.modelID
                ),
                variant: variant,
                parts: [PromptPart(type: "text", text: text)]
            )
        )
        _ = try await send(request)
    }

    func abort(sessionID: String) async throws {
        let request = makeRequest(
            pathComponents: ["session", sessionID, "abort"],
            method: "POST"
        )
        _ = try await send(request)
    }

    func eventStream() async throws -> OpenCodeLineStream {
        var request = makeRequest(pathComponents: ["event"], method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let stream = try await transport.stream(request)
            try validate(statusCode: stream.statusCode)
            return stream
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
        }
    }

    private func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        do {
            let response = try await transport.send(request)
            try validate(statusCode: response.statusCode)
            return response
        } catch let error as ProviderRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderRuntimeError.transport
        }
    }

    private func validate(statusCode: Int) throws {
        switch statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw ProviderRuntimeError.authenticationFailure
        case 500..<600:
            throw ProviderRuntimeError.unavailable
        default:
            throw ProviderRuntimeError.unexpectedResponse
        }
    }

    private func makeRequest(
        pathComponents: [String],
        method: String
    ) -> URLRequest {
        let url = pathComponents.reduce(connection.baseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            connection.authorizationHeader,
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func makeJSONRequest<Body: Encodable>(
        pathComponents: [String],
        method: String,
        body: Body
    ) throws -> URLRequest {
        var request = makeRequest(
            pathComponents: pathComponents,
            method: method
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderRuntimeError.unexpectedResponse
        }
    }

    private static func variantDisplayName(_ rawValue: String) -> String {
        rawValue == "xhigh" ? "XHigh" : rawValue.capitalized
    }

    private struct APIAuthBody: Encodable {
        let type: String
        let key: String
        let metadata: [String: String]?
    }

    private struct EmptyBody: Encodable {}

    private struct SessionResponse: Decodable {
        let id: String
    }

    private struct PromptBody: Encodable {
        let model: PromptModel
        let variant: String?
        let parts: [PromptPart]
    }

    private struct PromptModel: Encodable {
        let providerID: String
        let modelID: String
    }

    private struct PromptPart: Encodable {
        let type: String
        let text: String
    }
}

import Foundation

/// OpenCode `mcp` yapılandırmasındaki sunucu tanımı.
///
/// Yerel (`command`) ve uzak (`url`/`headers`/`oauth`) alanların ikisi de
/// taşınır; hangisinin geçerli olduğunu `type` belirler. Boş alanlar kodlanmaz.
struct OpenCodeMCPServerConfig: Encodable, Equatable, Sendable {
    let type: String
    let command: [String]
    let environment: [String: String]?
    let enabled: Bool
    let timeout: Int?
    var url: String? = nil
    var headers: [String: String]? = nil
    var cwd: String? = nil
    var oauth: OpenCodeMCPOAuthSetting? = nil
}

/// Uzak MCP sunucusu için OAuth davranışı.
///
/// `nil` (alan hiç yazılmaz) OpenCode'un otomatik OAuth akışını açar; `false`
/// API anahtarı kullanan sunucular için otomatik akışı kapatır; nesne ise önceden
/// kaydedilmiş istemci bilgilerini taşır.
enum OpenCodeMCPOAuthSetting: Encodable, Equatable, Sendable {
    case disabled
    case registered(clientID: String, clientSecret: String?, scope: String?)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .disabled:
            var container = encoder.singleValueContainer()
            try container.encode(false)
        case let .registered(clientID, clientSecret, scope):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(clientID, forKey: .clientId)
            try container.encodeIfPresent(clientSecret, forKey: .clientSecret)
            try container.encodeIfPresent(scope, forKey: .scope)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case clientId
        case clientSecret
        case scope
    }
}

/// `GET /mcp` yanıtındaki tek bir sunucunun durumu.
struct OpenCodeMCPServerStatus: Decodable, Equatable, Sendable {
    let status: String
    let error: String?

    var isConnected: Bool {
        status == "connected"
    }
}

protocol OpenCodeClientProtocol: Sendable {
    func capabilities() async throws -> ProviderCapabilities
    func authMethods() async throws -> [String: [OpenCodeAuthMethod]]
    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws
    func createSession() async throws -> String
    func deleteSession(sessionID: String) async throws
    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws
    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart],
        agent: String?
    ) async throws
    func abort(sessionID: String) async throws
    func eventStream() async throws -> OpenCodeLineStream
    func replyPermission(requestID: String, reply: String) async throws
    func pendingPermissions() async throws -> [OpenCodePermissionRequest]
    func replyQuestion(requestID: String, answers: [[String]]) async throws
    func rejectQuestion(requestID: String) async throws
    /// The tasks the agent is tracking for a session, as the backend keeps them.
    func sessionTodos(sessionID: String) async throws -> [AgentTodo]
    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus]
    func addMCPServer(
        name: String,
        config: OpenCodeMCPServerConfig
    ) async throws -> [String: OpenCodeMCPServerStatus]
    func disconnectMCPServer(name: String) async throws
    /// Starts a remote MCP server's OAuth flow and returns the page the user has
    /// to visit. `nil` means the server had nothing to authorize.
    func startMCPAuthorization(name: String) async throws -> URL?
    func completeMCPAuthorization(name: String, code: String) async throws
}

extension OpenCodeClientProtocol {
    // Older adapters can continue to handle the default build agent, but a
    // read-only plan is a security boundary. Never silently drop a custom agent
    // selection and execute its prompt under the default (possibly writable) one.
    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart],
        agent: String?
    ) async throws {
        guard agent == nil || agent == "build" else {
            throw ProviderRuntimeError.unavailable
        }
        try await sendPromptAsync(sessionID: sessionID, model: model, variant: variant, parts: parts)
    }

    func replyQuestion(requestID: String, answers: [[String]]) async throws {
        throw ProviderRuntimeError.unavailable
    }

    func rejectQuestion(requestID: String) async throws {
        throw ProviderRuntimeError.unavailable
    }

    func pendingPermissions() async throws -> [OpenCodePermissionRequest] {
        []
    }

    // Fakes in tests only ever answer the calls their test exercises; a server
    // that asks for no authorization is the honest default for them.
    func startMCPAuthorization(name: String) async throws -> URL? { nil }
    func completeMCPAuthorization(name: String, code: String) async throws {}
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

    /// Sunucu tarafındaki oturumu siler; silinen sohbetin arkasında ölü bir
    /// oturum bırakmamak için.
    func deleteSession(sessionID: String) async throws {
        let request = makeRequest(
            pathComponents: ["session", sessionID],
            method: "DELETE"
        )
        _ = try await send(request)
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        try await sendPromptAsync(
            sessionID: sessionID, model: model, variant: variant, parts: parts, agent: nil
        )
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart],
        agent: String?
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
                agent: agent,
                parts: parts
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

    func replyPermission(requestID: String, reply: String) async throws {
        let request = try makeJSONRequest(
            pathComponents: ["permission", requestID, "reply"],
            method: "POST",
            body: PermissionReplyBody(reply: reply)
        )
        _ = try await send(request)
    }

    func pendingPermissions() async throws -> [OpenCodePermissionRequest] {
        let request = makeRequest(
            pathComponents: ["permission"],
            method: "GET"
        )
        let response = try await send(request)
        guard
            let json = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]]
        else {
            return []
        }
        return json.compactMap { OpenCodePermissionRequest.make(from: $0) }
    }

    func replyQuestion(requestID: String, answers: [[String]]) async throws {
        let request = try makeJSONRequest(
            pathComponents: ["question", requestID, "reply"],
            method: "POST",
            body: QuestionReplyBody(answers: answers)
        )
        _ = try await send(request)
    }

    func rejectQuestion(requestID: String) async throws {
        let request = makeRequest(
            pathComponents: ["question", requestID, "reject"],
            method: "POST"
        )
        _ = try await send(request)
    }

    func sessionTodos(sessionID: String) async throws -> [AgentTodo] {
        let request = makeRequest(
            pathComponents: ["session", sessionID, "todo"],
            method: "GET"
        )
        let response = try await send(request)
        return try decode([AgentTodo].self, from: response.data)
    }

    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus] {
        let request = makeRequest(pathComponents: ["mcp"], method: "GET")
        let response = try await send(request)
        return try decode(
            [String: OpenCodeMCPServerStatus].self,
            from: response.data
        )
    }

    func addMCPServer(
        name: String,
        config: OpenCodeMCPServerConfig
    ) async throws -> [String: OpenCodeMCPServerStatus] {
        let request = try makeJSONRequest(
            pathComponents: ["mcp"],
            method: "POST",
            body: AddMCPServerBody(name: name, config: config)
        )
        let response = try await send(request)
        return try decode(
            [String: OpenCodeMCPServerStatus].self,
            from: response.data
        )
    }

    func disconnectMCPServer(name: String) async throws {
        let request = makeRequest(
            pathComponents: ["mcp", name, "disconnect"],
            method: "POST"
        )
        _ = try await send(request)
    }

    func startMCPAuthorization(name: String) async throws -> URL? {
        let request = makeRequest(
            pathComponents: ["mcp", name, "auth"],
            method: "POST"
        )
        let response = try await send(request)
        return Self.authorizationURL(in: response.data)
    }

    func completeMCPAuthorization(name: String, code: String) async throws {
        let request = try makeJSONRequest(
            pathComponents: ["mcp", name, "auth", "callback"],
            method: "POST",
            body: AuthorizationCallbackBody(code: code)
        )
        _ = try await send(request)
    }

    /// The field the flow's URL arrives in has moved between server versions, so
    /// the three names it has used are all read rather than one being trusted.
    static func authorizationURL(in data: Data) -> URL? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        for key in ["url", "authorizationUrl", "authorization_url"] {
            if let text = object[key] as? String, let url = URL(string: text) {
                return url
            }
        }

        return nil
    }

    private struct AuthorizationCallbackBody: Encodable {
        let code: String
    }

    func eventStream() async throws -> OpenCodeLineStream {
        var request = makeRequest(pathComponents: ["event"], method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let stream = try await transport.stream(request)
            try validate(statusCode: stream.statusCode)
            return stream
        } catch {
            throw ProviderRuntimeError.mapTransportError(error)
        }
    }

    private func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        do {
            let response = try await transport.send(request)
            try validate(statusCode: response.statusCode, body: response.data)
            return response
        } catch {
            throw ProviderRuntimeError.mapTransportError(error)
        }
    }

    /// `body` is used only for the statuses the shared policy does not name: the
    /// provider's own answer is then the only thing that can explain the failure,
    /// and without it the user saw one generic sentence.
    private func validate(statusCode: Int, body: Data = Data()) throws {
        guard !(200..<300).contains(statusCode) else {
            return
        }

        // Durum eşlemesi ortak politikadır; yerel sunucu için 401/403 reddedilen
        // sunucu kimlik bilgisi demektir.
        let mapped = ProviderRuntimeError.forHTTPStatus(
            statusCode,
            unauthorized: .authenticationFailure
        )

        if mapped == .unexpectedResponse, !body.isEmpty {
            ProviderResponseDiagnostics.shared.record(
                provider: "OpenCode",
                statusCode: statusCode,
                body: String(data: body, encoding: .utf8) ?? "<\(body.count) bytes>"
            )
        }

        throw mapped
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
        let agent: String?
        let parts: [OpenCodePromptPart]
    }

    private struct PromptModel: Encodable {
        let providerID: String
        let modelID: String
    }

    private struct PermissionReplyBody: Encodable {
        let reply: String
    }

    private struct QuestionReplyBody: Encodable {
        let answers: [[String]]
    }

    private struct AddMCPServerBody: Encodable {
        let name: String
        let config: OpenCodeMCPServerConfig
    }
}

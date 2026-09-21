import Foundation
import XCTest

@testable import AgenticSidebar

final class OpenCodeClientTests: XCTestCase {
    func testCapabilitiesExposeOnlyConnectedModelsWithFlattenedIDsAndSortedVariants() async throws {
        let transport = MockOpenCodeTransport(
            sendHandler: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/provider")
                return OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(
                        #"{"all":[{"id":"anthropic","name":"Anthropic","models":{"claude/opus":{"id":"claude/opus","providerID":"anthropic","name":"Claude Opus","variants":{"max":{},"high":{}}}}},{"id":"disconnected","name":"Disconnected","models":{"unused":{"id":"unused","providerID":"disconnected","name":"Unused","variants":{"low":{}}}}}],"connected":["anthropic"],"default":{}}"#
                            .utf8
                    )
                )
            }
        )
        let client = makeClient(transport: transport)

        let capabilities = try await client.capabilities()

        XCTAssertEqual(capabilities.id, ProviderID("opencode"))
        XCTAssertEqual(capabilities.displayName, "OpenCode")
        XCTAssertEqual(capabilities.models.map(\.id), [ProviderModelID("anthropic/claude/opus")])
        XCTAssertEqual(capabilities.models.first?.displayName, "Anthropic · Claude Opus")
        XCTAssertEqual(
            capabilities.models.first?.variants.map(\.id),
            [ProviderVariantID("high"), ProviderVariantID("max")]
        )

        let reference = try XCTUnwrap(
            OpenCodeModelReference(flattenedID: ProviderModelID("anthropic/claude/opus"))
        )
        XCTAssertEqual(reference.providerID, "anthropic")
        XCTAssertEqual(reference.modelID, "claude/opus")
    }

    func testCapabilitiesExposeModelContextLimitAndTolerateItsAbsence() async throws {
        let transport = MockOpenCodeTransport(
            sendHandler: { _ in
                OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(
                        #"{"all":[{"id":"anthropic","name":"Anthropic","models":{"known":{"id":"known","providerID":"anthropic","name":"Known","limit":{"context":200000,"output":32000}},"unknown":{"id":"unknown","providerID":"anthropic","name":"Unknown"}}}],"connected":["anthropic"],"default":{}}"#
                            .utf8
                    )
                )
            }
        )
        let client = makeClient(transport: transport)

        let capabilities = try await client.capabilities()
        let byID = Dictionary(uniqueKeysWithValues: capabilities.models.map { ($0.id, $0) })

        XCTAssertEqual(byID[ProviderModelID("anthropic/known")]?.contextLimit, 200_000)
        XCTAssertNil(byID[ProviderModelID("anthropic/unknown")]?.contextLimit)
    }

    func testAuthMethodsDecodeDynamicPromptsAndSetAPIKeyForwardsMetadata() async throws {
        let generatedKey = UUID().uuidString
        let transport = RecordingOpenCodeTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/provider/auth"):
                return OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(
                        #"{"cloudflare-workers-ai":[{"type":"api","label":"API key","prompts":[{"type":"text","key":"accountId","message":"Account ID","placeholder":"account"}]}],"openai":[{"type":"oauth","label":"Browser"}]}"#
                            .utf8
                    )
                )
            case ("PUT", "/auth/cloudflare-workers-ai"):
                return OpenCodeHTTPResponse(statusCode: 200, data: Data("true".utf8))
            default:
                XCTFail("Unexpected OpenCode request")
                return OpenCodeHTTPResponse(statusCode: 404, data: Data())
            }
        }
        let client = makeClient(transport: transport)

        let methods = try await client.authMethods()
        let apiMethod = try XCTUnwrap(methods["cloudflare-workers-ai"]?.first)
        XCTAssertEqual(apiMethod.type, .api)
        XCTAssertEqual(apiMethod.label, "API key")
        XCTAssertEqual(apiMethod.prompts?.first?.key, "accountId")
        XCTAssertEqual(methods["openai"]?.first?.type, .oauth)

        try await client.setAPIKey(
            providerID: "cloudflare-workers-ai",
            key: generatedKey,
            metadata: ["accountId": "account-123"]
        )

        let requests = await transport.requests()
        let put = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(put.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "api")
        XCTAssertEqual(object["key"] as? String, generatedKey)
        XCTAssertEqual(
            (object["metadata"] as? [String: String])?["accountId"],
            "account-123"
        )
    }

    func testSessionPromptAndAbortUseDocumentedEndpointsAndModelVariantShape() async throws {
        let transport = RecordingOpenCodeTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/session"):
                return OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"id":"ses_test"}"#.utf8)
                )
            case ("POST", "/session/ses_test/prompt_async"):
                return OpenCodeHTTPResponse(statusCode: 204, data: Data())
            case ("POST", "/session/ses_test/abort"):
                return OpenCodeHTTPResponse(statusCode: 200, data: Data("true".utf8))
            default:
                XCTFail("Unexpected OpenCode request")
                return OpenCodeHTTPResponse(statusCode: 404, data: Data())
            }
        }
        let client = makeClient(transport: transport)

        let sessionID = try await client.createSession()
        XCTAssertEqual(sessionID, "ses_test")

        try await client.sendPromptAsync(
            sessionID: sessionID,
            model: OpenCodeModelReference(providerID: "anthropic", modelID: "claude/opus"),
            variant: "high",
            parts: [
                .text("Hello"),
                .file(
                    mime: "image/png",
                    filename: "shot.png",
                    url: "data:image/png;base64,AAAA"
                ),
            ]
        )
        try await client.abort(sessionID: sessionID)

        let requests = await transport.requests()
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/session",
                "/session/ses_test/prompt_async",
                "/session/ses_test/abort",
            ])
        let promptBody = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: promptBody) as? [String: Any]
        )
        let model = try XCTUnwrap(object["model"] as? [String: String])
        XCTAssertEqual(model["providerID"], "anthropic")
        XCTAssertEqual(model["modelID"], "claude/opus")
        XCTAssertEqual(object["variant"] as? String, "high")
        let parts = try XCTUnwrap(object["parts"] as? [[String: String]])
        XCTAssertEqual(
            parts,
            [
                ["type": "text", "text": "Hello"],
                [
                    "type": "file",
                    "mime": "image/png",
                    "filename": "shot.png",
                    "url": "data:image/png;base64,AAAA",
                ],
            ])
    }

    func testEventStreamUsesAuthenticatedSSEEndpointAndPreservesCancellation() async throws {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        let cancellation = OpenCodeCancellationProbe()
        let transport = RecordingOpenCodeTransport(
            sendHandler: { _ in OpenCodeHTTPResponse(statusCode: 500, data: Data()) },
            streamHandler: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/event")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
                return OpenCodeLineStream(
                    statusCode: 200,
                    lines: pair.stream,
                    cancel: {
                        await cancellation.record()
                        pair.continuation.finish(throwing: CancellationError())
                    }
                )
            }
        )
        let client = makeClient(transport: transport)

        let stream = try await client.eventStream()
        await stream.cancel()

        let count = await cancellation.count()
        XCTAssertEqual(count, 1)
    }

    func testUnauthorizedResponseMapsToAuthenticationFailure() async {
        let transport = MockOpenCodeTransport(
            sendHandler: { _ in
                OpenCodeHTTPResponse(statusCode: 401, data: Data())
            }
        )
        let client = makeClient(transport: transport)

        await assertThrowsErrorAsync(
            try await client.capabilities()
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .authenticationFailure)
        }
    }

    func testMCPStatusAddAndDisconnectUseDocumentedEndpoints() async throws {
        let transport = RecordingOpenCodeTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/mcp"):
                return OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(
                        #"{"chatgpt-system":{"status":"connected"},"other":{"status":"failed","error":"boom"}}"#.utf8
                    )
                )
            case ("POST", "/mcp"):
                return OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"chatgpt-system":{"status":"connected","error":null}}"#.utf8)
                )
            case ("POST", "/mcp/chatgpt-system/disconnect"):
                return OpenCodeHTTPResponse(statusCode: 200, data: Data("true".utf8))
            default:
                XCTFail("Unexpected OpenCode request")
                return OpenCodeHTTPResponse(statusCode: 404, data: Data())
            }
        }
        let client = makeClient(transport: transport)

        let statuses = try await client.mcpServerStatuses()
        XCTAssertEqual(statuses["chatgpt-system"]?.isConnected, true)
        XCTAssertEqual(statuses["other"]?.status, "failed")
        XCTAssertEqual(statuses["other"]?.error, "boom")

        let added = try await client.addMCPServer(
            name: "chatgpt-system",
            config: OpenCodeMCPServerConfig(
                type: "local",
                command: ["/opt/homebrew/bin/node", "/tmp/cli.js", "stdio"],
                environment: nil,
                enabled: true,
                timeout: 20_000
            )
        )
        XCTAssertEqual(added["chatgpt-system"]?.isConnected, true)
        try await client.disconnectMCPServer(name: "chatgpt-system")

        let requests = await transport.requests()
        XCTAssertEqual(
            requests.map { $0.url?.path },
            ["/mcp", "/mcp", "/mcp/chatgpt-system/disconnect"]
        )
        let body = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["name"] as? String, "chatgpt-system")
        let config = try XCTUnwrap(object["config"] as? [String: Any])
        XCTAssertEqual(config["type"] as? String, "local")
        XCTAssertEqual(
            config["command"] as? [String],
            ["/opt/homebrew/bin/node", "/tmp/cli.js", "stdio"]
        )
        XCTAssertEqual(config["enabled"] as? Bool, true)
        XCTAssertEqual(config["timeout"] as? Int, 20_000)
        XCTAssertNil(config["environment"])
    }

    func testPlanPromptSelectsDedicatedReadOnlyAgent() async throws {
        let transport = RecordingOpenCodeTransport { _ in
            OpenCodeHTTPResponse(statusCode: 204, data: Data())
        }
        let client = makeClient(transport: transport)
        try await client.sendPromptAsync(
            sessionID: "plan-session",
            model: OpenCodeModelReference(providerID: "openai", modelID: "test"),
            variant: nil,
            parts: [.text("Inspect only")],
            agent: ManagedOpenCodeConfiguration.planAgentName
        )
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["agent"] as? String, ManagedOpenCodeConfiguration.planAgentName)
    }

    func testPlanAgentConfigurationDeniesMutationAllowsResearch() throws {
        let json = ManagedOpenCodeConfiguration.rendered(
            instructionPaths: [], permissionRules: [], extensions: .empty
        )
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let agents = try XCTUnwrap(config["agent"] as? [String: Any])
        let plan = try XCTUnwrap(agents[ManagedOpenCodeConfiguration.planAgentName] as? [String: Any])
        let permissions = try XCTUnwrap(plan["permission"] as? [String: String])
        XCTAssertEqual(permissions["*"], "deny")
        XCTAssertEqual(permissions["read"], "allow")
        XCTAssertEqual(permissions["glob"], "allow")
        XCTAssertEqual(permissions["grep"], "allow")
        XCTAssertEqual(permissions["list"], "allow")
        XCTAssertEqual(permissions["lsp"], "allow")
        XCTAssertEqual(permissions["question"], "allow")
        XCTAssertEqual(permissions["websearch"], "allow")
        XCTAssertEqual(permissions["webfetch"], "allow")
        XCTAssertEqual(permissions["todowrite"], "allow")
        XCTAssertEqual(permissions["task"], "ask")
        XCTAssertEqual(permissions["external_directory"], "allow")
        XCTAssertEqual(permissions["skill"], "allow")
        XCTAssertEqual(permissions["bash"], nil)
        XCTAssertEqual(permissions["edit"], nil)
        XCTAssertEqual(permissions["write"], nil)
        XCTAssertEqual(permissions["patch"], nil)
        XCTAssertEqual(permissions["multiedit"], nil)
        XCTAssertEqual(permissions.count, 13)
    }

    func testResearchSubagentIsReadOnlyAndCannotDelegateFurther() throws {
        let json = ManagedOpenCodeConfiguration.rendered(
            instructionPaths: [], permissionRules: [], extensions: .empty
        )
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let agents = try XCTUnwrap(config["agent"] as? [String: Any])
        let research = try XCTUnwrap(agents[ManagedOpenCodeConfiguration.researchAgentName] as? [String: Any])
        XCTAssertEqual(research["mode"] as? String, "subagent")
        let permissions = try XCTUnwrap(research["permission"] as? [String: String])
        XCTAssertEqual(permissions["*"], "deny")
        XCTAssertEqual(permissions["read"], "allow")
        XCTAssertEqual(permissions["glob"], "allow")
        XCTAssertEqual(permissions["grep"], "allow")
        XCTAssertEqual(permissions["list"], "allow")
        XCTAssertEqual(permissions["lsp"], "allow")
        XCTAssertEqual(permissions["question"], "allow")
        XCTAssertEqual(permissions["websearch"], "allow")
        XCTAssertEqual(permissions["webfetch"], "allow")
        XCTAssertEqual(permissions["todowrite"], "allow")
        XCTAssertEqual(permissions["task"], "deny")
        XCTAssertEqual(permissions["external_directory"], "allow")
        XCTAssertEqual(permissions["skill"], "allow")
        XCTAssertEqual(permissions["bash"], nil)
        XCTAssertEqual(permissions["edit"], nil)
        XCTAssertEqual(permissions["write"], nil)
        XCTAssertEqual(permissions["patch"], nil)
        XCTAssertEqual(permissions["multiedit"], nil)
        XCTAssertEqual(permissions.count, 13)
    }

    func testQuestionReplyAndRejectUseBackendRequestIDAndStructuredAnswers() async throws {
        let transport = RecordingOpenCodeTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return OpenCodeHTTPResponse(statusCode: 200, data: Data("true".utf8))
        }
        let client = makeClient(transport: transport)

        try await client.replyQuestion(
            requestID: "que_123",
            answers: [["PostgreSQL"], ["Redis", "Custom detail"]]
        )
        try await client.rejectQuestion(requestID: "que_456")

        let requests = await transport.requests()
        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/question/que_123/reply",
                "/question/que_456/reject",
            ])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(requests[0].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            object["answers"] as? [[String]],
            [
                ["PostgreSQL"], ["Redis", "Custom detail"],
            ])
        XCTAssertNil(requests[1].httpBody)
        XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "Authorization"))
    }

    func testPendingPermissionsAndReplyPermission() async throws {
        let transport = RecordingOpenCodeTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/permission"):
                return OpenCodeHTTPResponse(
                    statusCode: 200,
                    data: Data(
                        #"[{"id":"perm_1","sessionID":"ses_1","permission":"bash","patterns":["echo hi"],"always":["echo *"]}]"#.utf8
                    )
                )
            case ("POST", "/permission/perm_1/reply"):
                return OpenCodeHTTPResponse(statusCode: 200, data: Data("true".utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return OpenCodeHTTPResponse(statusCode: 404, data: Data())
            }
        }
        let client = makeClient(transport: transport)

        let pending = try await client.pendingPermissions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, "perm_1")
        XCTAssertEqual(pending.first?.toolName, "bash")
        XCTAssertEqual(pending.first?.patterns, ["echo hi"])

        try await client.replyPermission(requestID: "perm_1", reply: "once")

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/permission")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/permission/perm_1/reply")
    }

    private func makeClient(transport: any OpenCodeTransport) -> OpenCodeClient {
        OpenCodeClient(
            transport: transport,
            connection: OpenCodeServerConnection(
                baseURL: URL(string: "http://127.0.0.1:51170")!,
                username: "opencode",
                password: "server-password"
            )
        )
    }
}

private actor MockOpenCodeTransport: OpenCodeTransport {
    typealias SendHandler = @Sendable (URLRequest) async throws -> OpenCodeHTTPResponse
    typealias StreamHandler = @Sendable (URLRequest) async throws -> OpenCodeLineStream

    private let sendHandler: SendHandler
    private let streamHandler: StreamHandler

    init(
        sendHandler: @escaping SendHandler,
        streamHandler: @escaping StreamHandler = { _ in
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            pair.continuation.finish()
            return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
        }
    ) {
        self.sendHandler = sendHandler
        self.streamHandler = streamHandler
    }

    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        try await sendHandler(request)
    }

    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream {
        try await streamHandler(request)
    }
}

private actor RecordingOpenCodeTransport: OpenCodeTransport {
    typealias SendHandler = @Sendable (URLRequest) async throws -> OpenCodeHTTPResponse
    typealias StreamHandler = @Sendable (URLRequest) async throws -> OpenCodeLineStream

    private let sendHandler: SendHandler
    private let streamHandler: StreamHandler
    private var recordedRequests: [URLRequest] = []

    init(
        sendHandler: @escaping SendHandler,
        streamHandler: @escaping StreamHandler = { _ in
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            pair.continuation.finish()
            return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
        }
    ) {
        self.sendHandler = sendHandler
        self.streamHandler = streamHandler
    }

    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        recordedRequests.append(request)
        return try await sendHandler(request)
    }

    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream {
        recordedRequests.append(request)
        return try await streamHandler(request)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor OpenCodeCancellationProbe {
    private var cancellationCount = 0
    func record() { cancellationCount += 1 }
    func count() -> Int { cancellationCount }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

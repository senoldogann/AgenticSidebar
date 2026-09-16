import Foundation
import XCTest
@testable import AgenticSidebar

final class OpenCodeProviderRuntimeTests: XCTestCase {
    func testCapabilitiesRequiresAlreadyRunningManagedServer() async {
        let client = RuntimeMockOpenCodeClient()
        let runtime = OpenCodeProviderRuntime(
            serverManager: StubRuntimeOpenCodeServerManager(connection: nil),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        await XCTAssertThrowsErrorAsync(
            try await runtime.capabilities()
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .unavailable)
        }
        let calls = await client.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testCapabilitiesForwardConnectedOpenCodeCapabilities() async throws {
        let expected = ProviderCapabilities(
            id: ProviderID("opencode"),
            displayName: "OpenCode",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("anthropic/claude-opus"),
                    displayName: "Anthropic · Claude Opus",
                    variants: [
                        ProviderVariant(
                            id: ProviderVariantID("high"),
                            displayName: "High"
                        )
                    ]
                )
            ]
        )
        let client = RuntimeMockOpenCodeClient(capabilities: expected)
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)

        let actual = try await runtime.capabilities()

        XCTAssertEqual(runtime.id, ProviderID("opencode"))
        XCTAssertEqual(actual, expected)
    }

    func testFirstTurnCreatesSessionAndNextTurnReusesItWithEventSubscriptionBeforePrompt() async throws {
        let firstStream = completedLineStream(sessionID: "ses_remote")
        let secondStream = completedLineStream(sessionID: "ses_remote")
        let client = RuntimeMockOpenCodeClient(
            eventStreams: [firstStream, secondStream]
        )
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)
        let appSessionID = UUID()
        let request = makeRequest(sessionID: appSessionID, text: "First")

        let first = try await runtime.startStream(for: request)
        _ = try await collect(first.events)

        let second = try await runtime.startStream(
            for: makeRequest(sessionID: appSessionID, text: "Second")
        )
        _ = try await collect(second.events)

        let calls = await client.calls()
        XCTAssertEqual(
            calls,
            [
                .createSession,
                .eventStream,
                .prompt(
                    sessionID: "ses_remote",
                    model: OpenCodeModelReference(
                        providerID: "anthropic",
                        modelID: "claude/opus"
                    ),
                    variant: "high",
                    text: "First"
                ),
                .eventStream,
                .prompt(
                    sessionID: "ses_remote",
                    model: OpenCodeModelReference(
                        providerID: "anthropic",
                        modelID: "claude/opus"
                    ),
                    variant: "high",
                    text: "Second"
                )
            ]
        )
    }

    func testRuntimeNormalizesTextToolAndCompletionEvents() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        linePair.continuation.yield(
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_remote","part":{"id":"prt_text","sessionID":"ses_remote","messageID":"msg_1","type":"text","text":""},"time":1}}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_remote","messageID":"msg_1","partID":"prt_text","field":"text","delta":"Hello"}}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_remote","part":{"id":"prt_tool","sessionID":"ses_remote","messageID":"msg_1","type":"tool","callID":"call_1","tool":"read","state":{"status":"running","input":{},"time":{"start":1}}},"time":1}}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_remote","part":{"id":"prt_tool","sessionID":"ses_remote","messageID":"msg_1","type":"tool","callID":"call_1","tool":"read","state":{"status":"completed","input":{},"output":"ok","title":"done","metadata":{},"time":{"start":1,"end":2}}},"time":2}}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"session.status","properties":{"sessionID":"ses_remote","status":{"type":"idle"}}}"#
        )
        linePair.continuation.finish()

        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(statusCode: 200, lines: linePair.stream)
            ]
        )
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Run")
        )
        let events = try await collect(stream.events)

        XCTAssertEqual(
            events,
            [
                .assistantTextDelta("Hello"),
                .activityStarted(
                    ProviderActivityDescriptor(
                        id: ProviderActivityID("prt_tool"),
                        kind: .read
                    )
                ),
                // The tool's result only exists on the backend's final part
                // update, so it rides along with the terminal event.
                .activityFinished(
                    ProviderActivityID("prt_tool"),
                    outcome: .completed,
                    output: "ok"
                ),
                .completed
            ]
        )
    }

    func testCompletionCancelsUnderlyingEventStream() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        let cancellationProbe = RuntimeOpenCodeCancellationProbe()
        linePair.continuation.yield(
            #"data: {"type":"session.status","properties":{"sessionID":"ses_remote","status":{"type":"idle"}}}"#
        )

        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(
                    statusCode: 200,
                    lines: linePair.stream,
                    cancel: {
                        await cancellationProbe.record()
                        linePair.continuation.finish(throwing: CancellationError())
                    }
                )
            ]
        )
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Done")
        )
        let events = try await collect(stream.events)

        XCTAssertEqual(events, [.completed])
        let cancellationCount = await cancellationProbe.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testPromptFailureCancelsAlreadyOpenedEventStream() async {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        let cancellationProbe = RuntimeOpenCodeCancellationProbe()
        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(
                    statusCode: 200,
                    lines: linePair.stream,
                    cancel: {
                        await cancellationProbe.record()
                        linePair.continuation.finish(throwing: CancellationError())
                    }
                )
            ],
            promptError: ProviderRuntimeError.transport
        )
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)

        await XCTAssertThrowsErrorAsync(
            try await runtime.startStream(
                for: makeRequest(sessionID: UUID(), text: "Fail")
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .transport)
        }

        let cancellationCount = await cancellationProbe.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testCancellationAbortsOpenCodeSessionAndCancelsUnderlyingEventStream() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        let cancellationProbe = RuntimeOpenCodeCancellationProbe()
        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(
                    statusCode: 200,
                    lines: linePair.stream,
                    cancel: {
                        await cancellationProbe.record()
                        linePair.continuation.finish(throwing: CancellationError())
                    }
                )
            ]
        )
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Long task")
        )
        await stream.cancel()

        let calls = await client.calls()
        XCTAssertTrue(calls.contains(.abort(sessionID: "ses_remote")))
        let cancellationCount = await cancellationProbe.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testPermissionRequestWaitsForTheInjectedHandler() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        linePair.continuation.yield(
            #"data: {"type":"permission.asked","properties":{"sessionID":"ses_remote","id":"per_1","permission":"chatgpt-system_computer_click","patterns":["*"],"always":["chatgpt-system_computer_click*"],"metadata":{}}}"#
        )
        linePair.continuation.yield(
            #"data: {"type":"session.status","properties":{"sessionID":"ses_remote","status":{"type":"idle"}}}"#
        )
        linePair.continuation.finish()

        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(statusCode: 200, lines: linePair.stream)
            ]
        )
        let runtime = makeRuntime(
            client: client,
            permissionHandler: { request in
                XCTAssertEqual(request.toolName, "chatgpt-system_computer_click")
                return .reject
            },
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Click Run")
        )
        _ = try await collect(stream.events)

        let delivered = await waitForCall(
            .replyPermission(requestID: "per_1", reply: "reject"),
            on: client
        )
        XCTAssertTrue(delivered, "The handler's decision must reach OpenCode")
    }

    /// Fail closed: a runtime with no decision surface must not read as consent.
    /// `.always` would have been worse than `.once` as a default, because OpenCode
    /// remembers it for the rest of the server session.
    func testWithoutAHandlerPermissionsAreRefused() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        linePair.continuation.yield(
            #"data: {"type":"permission.asked","properties":{"sessionID":"ses_remote","id":"per_2","permission":"bash","patterns":["*"],"always":[],"metadata":{}}}"#
        )
        linePair.continuation.finish()

        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(statusCode: 200, lines: linePair.stream)
            ]
        )
        let runtime = makeRuntime(
            client: client,
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Run")
        )

        let delivered = await waitForCall(
            .replyPermission(requestID: "per_2", reply: "reject"),
            on: client
        )
        XCTAssertTrue(delivered, "A missing handler is a wiring mistake, not permission")

        await stream.cancel()
    }

    func testCancellationClearsPendingPermissionsForTheRemoteSession() async throws {
        let linePair = AsyncThrowingStream<String, Error>.makeStream()
        let probe = RuntimePermissionCancellationProbe()
        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                OpenCodeLineStream(statusCode: 200, lines: linePair.stream)
            ]
        )
        let runtime = makeRuntime(
            client: client,
            permissionHandler: { _ in .once },
            cancelPendingPermissions: { remoteSessionID in
                await probe.record(remoteSessionID: remoteSessionID)
            }
        )

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Long task")
        )
        await stream.cancel()

        let sessionIDs = await probe.sessionIDs()
        XCTAssertEqual(sessionIDs, ["ses_remote"])
    }

    func testReleasingASessionDeletesTheRemoteSessionAndForgetsIt() async throws {
        let client = RuntimeMockOpenCodeClient(
            eventStreams: [
                completedLineStream(sessionID: "ses_remote"),
                completedLineStream(sessionID: "ses_remote")
            ]
        )
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)
        let appSessionID = UUID()

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: appSessionID, text: "First")
        )
        _ = try await collect(stream.events)

        await runtime.releaseSession(appSessionID)

        let callsAfterRelease = await client.calls()
        XCTAssertTrue(
            callsAfterRelease.contains(.deleteSession(sessionID: "ses_remote")),
            "A deleted conversation must not leave a live session behind on the server"
        )

        // Aynı uygulama oturumu yeniden kullanılırsa uzak oturum sıfırdan kurulur.
        let second = try await runtime.startStream(
            for: makeRequest(sessionID: appSessionID, text: "Second")
        )
        _ = try await collect(second.events)

        let finalCalls = await client.calls()
        XCTAssertEqual(finalCalls.filter { $0 == .createSession }.count, 2)
    }

    func testReleasingAnUnknownSessionAsksTheServerForNothing() async {
        let client = RuntimeMockOpenCodeClient()
        let runtime = makeRuntime(client: client, permissionHandler: nil, cancelPendingPermissions: nil)

        await runtime.releaseSession(UUID())

        let calls = await client.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    private func makeRuntime(
        client: RuntimeMockOpenCodeClient,
        permissionHandler: OpenCodeProviderRuntime.PermissionHandler?,
        cancelPendingPermissions: OpenCodeProviderRuntime.PermissionCancellationHandler?
    ) -> OpenCodeProviderRuntime {
        OpenCodeProviderRuntime(
            serverManager: StubRuntimeOpenCodeServerManager(
                connection: OpenCodeServerConnection(
                    baseURL: URL(string: "http://127.0.0.1:51180")!,
                    username: "opencode",
                    password: "server-password"
                )
            ),
            clientFactory: { _ in client },
            permissionHandler: permissionHandler,
            cancelPendingPermissions: cancelPendingPermissions
        )
    }

    /// Handler yanıtı ayrı bir Task içinde gönderilir; kaydı beklemek gerekir.
    private func waitForCall(
        _ expected: RuntimeOpenCodeCall,
        on client: RuntimeMockOpenCodeClient
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await client.calls().contains(expected) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func makeRequest(
        sessionID: UUID,
        text: String
    ) -> ProviderRequest {
        ProviderRequest(
            sessionID: sessionID,
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude/opus"),
                variantID: ProviderVariantID("high")
            ),
            messages: [ChatMessage(role: .user, text: text)],
            speedMode: .normal
        )
    }

    private func completedLineStream(sessionID: String) -> OpenCodeLineStream {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.yield(
            "data: {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"\(sessionID)\",\"status\":{\"type\":\"idle\"}}}"
        )
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    private func collect(
        _ stream: AsyncThrowingStream<ProviderEvent, Error>
    ) async throws -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}

private struct StubRuntimeOpenCodeServerManager: OpenCodeServerManaging {
    let connection: OpenCodeServerConnection?

    func status() async -> OpenCodeServerStatus {
        if let connection {
            return .running(version: "1.18.31", baseURL: connection.baseURL)
        }
        return .stopped
    }

    func start(computerUse: ComputerUseConfiguration?) async throws -> OpenCodeServerConnection {
        guard let connection else {
            throw ProviderRuntimeError.unavailable
        }
        return connection
    }

    func currentConnection() async -> OpenCodeServerConnection? {
        connection
    }

    func stop() async {}
}

/// Text summary of a prompt so call assertions can keep comparing strings.
private func openCodePromptText(from parts: [OpenCodePromptPart]) -> String {
    parts.compactMap { part -> String? in
        if case let .text(text) = part { return text }
        return nil
    }.joined(separator: "\n")
}

private enum RuntimeOpenCodeCall: Equatable, Sendable {
    case capabilities
    case createSession
    case eventStream
    case prompt(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        text: String
    )
    case abort(sessionID: String)
    case replyPermission(requestID: String, reply: String)
    case deleteSession(sessionID: String)
}

private actor RuntimeMockOpenCodeClient: OpenCodeClientProtocol {
    private let capabilitySet: ProviderCapabilities
    private var streams: [OpenCodeLineStream]
    private let promptError: Error?
    private var recordedCalls: [RuntimeOpenCodeCall] = []

    init(
        capabilities: ProviderCapabilities = ProviderCapabilities(
            id: ProviderID("opencode"),
            displayName: "OpenCode",
            models: []
        ),
        eventStreams: [OpenCodeLineStream] = [],
        promptError: Error? = nil
    ) {
        self.capabilitySet = capabilities
        self.streams = eventStreams
        self.promptError = promptError
    }

    func capabilities() async throws -> ProviderCapabilities {
        recordedCalls.append(.capabilities)
        return capabilitySet
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] {
        [:]
    }

    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws {}

    func createSession() async throws -> String {
        recordedCalls.append(.createSession)
        return "ses_remote"
    }

    func deleteSession(sessionID: String) async throws {
        recordedCalls.append(.deleteSession(sessionID: sessionID))
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        let text = parts.compactMap { part -> String? in
            if case let .text(str) = part { return str }
            return nil
        }.joined(separator: "\n")
        recordedCalls.append(
            .prompt(
                sessionID: sessionID,
                model: model,
                variant: variant,
                text: text
            )
        )
        if let promptError {
            throw promptError
        }
    }

    func abort(sessionID: String) async throws {
        recordedCalls.append(.abort(sessionID: sessionID))
    }

    func replyPermission(requestID: String, reply: String) async throws {
        recordedCalls.append(.replyPermission(requestID: requestID, reply: reply))
    }

    func sessionTodos(sessionID: String) async throws -> [AgentTodo] {
        []
    }

    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus] {
        [:]
    }

    func addMCPServer(
        name: String,
        config: OpenCodeMCPServerConfig
    ) async throws -> [String: OpenCodeMCPServerStatus] {
        [:]
    }

    func disconnectMCPServer(name: String) async throws {}


    func eventStream() async throws -> OpenCodeLineStream {
        recordedCalls.append(.eventStream)
        guard !streams.isEmpty else {
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            pair.continuation.finish()
            return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
        }
        return streams.removeFirst()
    }

    func calls() -> [RuntimeOpenCodeCall] {
        recordedCalls
    }
}

private actor RuntimeOpenCodeCancellationProbe {
    private var cancellationCount = 0
    func record() { cancellationCount += 1 }
    func count() -> Int { cancellationCount }
}

private actor RuntimePermissionCancellationProbe {
    private var cancelledSessionIDs: [String] = []
    func record(remoteSessionID: String) { cancelledSessionIDs.append(remoteSessionID) }
    func sessionIDs() -> [String] { cancelledSessionIDs }
}

private func XCTAssertThrowsErrorAsync<T>(
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

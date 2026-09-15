import Foundation
import XCTest
@testable import AgenticSidebar

final class OpenCodeProviderRuntimeTests: XCTestCase {
    func testCapabilitiesRequiresAlreadyRunningManagedServer() async {
        let client = RuntimeMockOpenCodeClient()
        let runtime = OpenCodeProviderRuntime(
            serverManager: StubRuntimeOpenCodeServerManager(connection: nil),
            clientFactory: { _ in client }
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
        let runtime = makeRuntime(client: client)

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
        let runtime = makeRuntime(client: client)
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
        let runtime = makeRuntime(client: client)

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
                .activityFinished(
                    ProviderActivityID("prt_tool"),
                    outcome: .completed
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
        let runtime = makeRuntime(client: client)

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
        let runtime = makeRuntime(client: client)

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
        let runtime = makeRuntime(client: client)

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID(), text: "Long task")
        )
        await stream.cancel()

        let calls = await client.calls()
        XCTAssertTrue(calls.contains(.abort(sessionID: "ses_remote")))
        let cancellationCount = await cancellationProbe.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    private func makeRuntime(
        client: RuntimeMockOpenCodeClient
    ) -> OpenCodeProviderRuntime {
        OpenCodeProviderRuntime(
            serverManager: StubRuntimeOpenCodeServerManager(
                connection: OpenCodeServerConnection(
                    baseURL: URL(string: "http://127.0.0.1:51180")!,
                    username: "opencode",
                    password: "server-password"
                )
            ),
            clientFactory: { _ in client }
        )
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
            messages: [ChatMessage(role: .user, text: text)]
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

    func start() async throws -> OpenCodeServerConnection {
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

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        text: String
    ) async throws {
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

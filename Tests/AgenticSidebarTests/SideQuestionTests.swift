import Foundation
import XCTest

@testable import AgenticSidebar

/// Yan soru (`/btw`) sözleşmesi: kesintisiz soru, araçsız yanıt, kirlenmeyen
/// geçmiş, her yolda silinen geçici oturum.
///
/// Çıta: önek yalnız `/btw ` yakalar; bellek oturum başına 20'de kapaklıdır;
/// desteklemeyen provider `.unsupported` döner; OpenCode geçici oturumu
/// salt-okunur ajanla açıp kapatır, izni reddeder, yalnız metin akıtır.
@MainActor
final class SideQuestionTests: XCTestCase {
    // MARK: - Önek yakalama

    func testSideQuestionPrefixParsing() {
        XCTAssertEqual(ComposerView.sideQuestion(from: "/btw soru nedir?"), "soru nedir?")
        XCTAssertEqual(ComposerView.sideQuestion(from: "/BTW Büyük harf"), "Büyük harf")
        XCTAssertEqual(
            ComposerView.sideQuestion(from: "/btw   boşluklu   "),
            "boşluklu"
        )
        XCTAssertNil(ComposerView.sideQuestion(from: "/btw"))
        XCTAssertNil(ComposerView.sideQuestion(from: "/btw "))
        XCTAssertNil(ComposerView.sideQuestion(from: "/btw   "))
        XCTAssertNil(ComposerView.sideQuestion(from: "/btwx bitişik"))
        XCTAssertNil(ComposerView.sideQuestion(from: "normal ileti /btw değil"))
        XCTAssertNil(ComposerView.sideQuestion(from: "düz ileti"))
    }

    // MARK: - Bellek

    func testMemoryCapsExchangesPerSession() {
        var memory = SideQuestionMemory()
        let sessionID = UUID()
        for index in 0..<25 {
            memory.append(
                sessionID: sessionID,
                exchange: SideExchange(question: "s\(index)", answer: "c\(index)")
            )
        }
        let kept = memory.exchanges(for: sessionID)
        XCTAssertEqual(kept.count, SideQuestionMemory.maximumExchangesPerSession)
        XCTAssertEqual(kept.first?.question, "s5")
        XCTAssertEqual(kept.last?.question, "s24")
    }

    func testMemoryDropClearsSession() {
        var memory = SideQuestionMemory()
        let sessionID = UUID()
        memory.append(sessionID: sessionID, exchange: SideExchange(question: "s", answer: "c"))
        memory.drop(sessionID: sessionID)
        XCTAssertTrue(memory.exchanges(for: sessionID).isEmpty)
    }

    // MARK: - Protokol varsayılanı

    func testDefaultAnswerSideQuestionThrowsUnsupported() async {
        let runtime = TestProviderRuntime(
            id: ProviderID("legacy"),
            displayName: "Legacy",
            models: []
        )
        do {
            _ = try await runtime.answerSideQuestion(Self.query())
            XCTFail("Desteklemeyen provider sormalı değil, atmalı")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .unsupported)
        }
    }

    // MARK: - Servis

    func testAskStreamsAnswerAndRemembers() async {
        let runtime = ScriptedSideRuntime(script: .answer(["Mer", "haba"]))
        let service = SideQuestionService()
        let context = SideQuestionContext(
            runtime: runtime,
            configuration: Self.configuration(),
            messages: [ChatMessage(role: .user, text: "geçmiş")],
            activityGroups: []
        )

        service.ask(
            context: context,
            sessionID: UUID(),
            question: "soru?",
            speedMode: .normal,
            mode: .build
        )

        let final = await Self.waitForInactive(service: service)
        XCTAssertEqual(final?.phase, .done)
        XCTAssertEqual(final?.answer, "Merhaba")
        XCTAssertEqual(service.exchanges(for: final?.sessionID ?? UUID()).count, 1)
        // Girdi bağlamı el değmemiş durur: servis transkripte yazmaz.
        XCTAssertEqual(context.messages.map(\.text), ["geçmiş"])
    }

    func testAskFailureSurfacesMessage() async {
        let runtime = ScriptedSideRuntime(script: .failure(ProviderRuntimeError.transport))
        let service = SideQuestionService()

        service.ask(
            context: SideQuestionContext(
                runtime: runtime,
                configuration: Self.configuration(),
                messages: [],
                activityGroups: []
            ),
            sessionID: UUID(),
            question: "soru?",
            speedMode: .normal,
            mode: .build
        )

        let final = await Self.waitForInactive(service: service)
        XCTAssertEqual(final?.phase, .failed)
        XCTAssertFalse(final?.errorText?.isEmpty ?? true)
    }

    func testCancelMarksCancelled() async {
        let runtime = ScriptedSideRuntime(script: .hang)
        let service = SideQuestionService()

        service.ask(
            context: SideQuestionContext(
                runtime: runtime,
                configuration: Self.configuration(),
                messages: [],
                activityGroups: []
            ),
            sessionID: UUID(),
            question: "soru?",
            speedMode: .normal,
            mode: .build
        )
        try? await Task.sleep(for: .milliseconds(50))
        service.cancelStreaming()

        let final = await Self.waitForInactive(service: service)
        XCTAssertEqual(final?.phase, .cancelled)
    }

    func testFailShowsMessageWithoutContext() {
        let service = SideQuestionService()
        let sessionID = UUID()
        service.fail(sessionID: sessionID, question: "soru?", message: "sağlayıcı yok")
        XCTAssertEqual(service.active?.phase, .failed)
        XCTAssertEqual(service.active?.errorText, "sağlayıcı yok")
    }

    func testSecondAskInvalidatesFirstAnswer() async {
        let runtime = QuestionGatedSideRuntime()
        let service = SideQuestionService()
        let sessionID = UUID()
        func context() -> SideQuestionContext {
            SideQuestionContext(
                runtime: runtime,
                configuration: Self.configuration(),
                messages: [],
                activityGroups: []
            )
        }
        service.ask(context: context(), sessionID: sessionID, question: "first", speedMode: .normal, mode: .build)
        try? await Task.sleep(for: .milliseconds(20))
        service.ask(context: context(), sessionID: sessionID, question: "second", speedMode: .normal, mode: .build)
        let final = await Self.waitForInactive(service: service)
        XCTAssertEqual(final?.question, "second")
        XCTAssertEqual(final?.answer, "FRESH")
        XCTAssertEqual(final?.phase, .done)
    }

    // MARK: - OpenCode runtime

    func testEphemeralLifecycleUsesReadonlyAgentAndDeletesSession() async throws {
        let lines = AsyncThrowingStream<String, Error>.makeStream()
        lines.continuation.yield(
            #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_side","messageID":"msg_1","partID":"prt_1","field":"text","delta":"Yanıt"}}"#
        )
        lines.continuation.yield(
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_side","part":{"id":"prt_1","sessionID":"ses_side","messageID":"msg_1","type":"text","text":"Yanıt"},"time":1}}"#
        )
        lines.continuation.yield(
            #"data: {"type":"session.idle","properties":{"sessionID":"ses_side"}}"#
        )
        lines.continuation.finish()

        let client = SideFakeOpenCodeClient(
            lines: lines.stream,
            remoteSessionID: "ses_side"
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: SideStubServerManager(),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.answerSideQuestion(Self.openCodeQuery())
        var text = ""
        for try await event in stream.events {
            if case .assistantTextDelta(let delta) = event {
                text += delta
            }
        }
        XCTAssertEqual(text, "Yanıt")

        let calls = await client.recordedCalls()
        // Geçici oturum: önce açılır, soru onda sorulur, sonunda silinir.
        XCTAssertEqual(calls.first, .createSession)
        XCTAssertEqual(calls.last, .deleteSession(sessionID: "ses_side"))
        guard
            case .prompt(let sessionID, _, let promptText) = calls.first(where: {
                if case .prompt = $0 { return true }
                return false
            })
        else {
            return XCTFail("Prompt gönderilmedi")
        }
        XCTAssertEqual(sessionID, "ses_side")
        XCTAssertTrue(promptText.contains("neredeyiz?"), "Soru taşınmalı")
        XCTAssertTrue(promptText.contains("eski bağlam"), "Geçmiş preamble ile taşınmalı")
        let agents = await client.recordedAgents()
        XCTAssertEqual(agents, [ManagedOpenCodeConfiguration.planAgentName])
    }

    func testSidePermissionIsAutoRejected() async throws {
        let lines = AsyncThrowingStream<String, Error>.makeStream()
        lines.continuation.yield(
            #"data: {"type":"permission.asked","properties":{"sessionID":"ses_side","id":"per_side","permission":"bash","patterns":["ls"],"always":[]}}"#
        )
        lines.continuation.yield(
            #"data: {"type":"session.idle","properties":{"sessionID":"ses_side"}}"#
        )
        lines.continuation.finish()

        let client = SideFakeOpenCodeClient(
            lines: lines.stream,
            remoteSessionID: "ses_side"
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: SideStubServerManager(),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.answerSideQuestion(Self.openCodeQuery())
        for try await _ in stream.events {}

        let replies = await client.recordedReplies()
        XCTAssertTrue(
            replies.contains(.replyPermission(requestID: "per_side", reply: "reject")),
            "Yan soruda izin panele çıkmaz, reddedilir"
        )
    }

    func testWrongProviderIsRejected() async throws {
        let client = SideFakeOpenCodeClient(
            lines: AsyncThrowingStream<String, Error>.makeStream().stream,
            remoteSessionID: "ses_side"
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: SideStubServerManager(),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        var query = Self.openCodeQuery()
        query = SideQuestionQuery(
            configuration: SessionConfiguration(
                providerID: ProviderID("baska"),
                modelID: ProviderModelID("x/y"),
                variantID: nil
            ),
            historyMessages: query.historyMessages,
            activityGroups: [],
            followups: [],
            question: "soru?",
            speedMode: .normal,
            mode: .build
        )
        do {
            _ = try await runtime.answerSideQuestion(query)
            XCTFail("Yanlış sağlayıcı reddedilmeli")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .unexpectedResponse)
        }
    }

    func testEventStreamFailureStillDeletesEphemeralSession() async {
        let lines = AsyncThrowingStream<String, Error>.makeStream()
        lines.continuation.finish()
        let client = SideFakeOpenCodeClient(
            lines: lines.stream,
            remoteSessionID: "ses_side",
            eventStreamError: ProviderRuntimeError.transport
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: SideStubServerManager(),
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        do {
            _ = try await runtime.answerSideQuestion(Self.openCodeQuery())
            XCTFail("Akış açılamazsa soru sorulmamalı")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .transport)
        }

        let calls = await client.recordedCalls()
        XCTAssertTrue(
            calls.contains(.deleteSession(sessionID: "ses_side")),
            "Abonelik kurulamadan atılan hata geçici oturumu sızdırmamalı"
        )
    }

    // MARK: - OpenAI runtime

    func testOpenAISideQuestionCarriesHistoryAndStreams() async throws {
        let lines = AsyncThrowingStream<String, Error>.makeStream()
        lines.continuation.yield(
            #"data: {"type":"response.output_text.delta","delta":"Hello"}"#
        )
        lines.continuation.yield(
            #"data: {"type":"response.output_text.delta","delta":" world"}"#
        )
        lines.continuation.yield(
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#
        )
        lines.continuation.finish()

        let transport = SideFakeOpenAITransport(lines: lines.stream)
        let runtime = OpenAIProviderRuntime(
            transport: transport,
            credentialStore: SideStubCredentialStore(value: "test-key"),
            baseURL: URL(string: "https://example.test/v1")!
        )
        let query = SideQuestionQuery(
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: nil
            ),
            historyMessages: [ChatMessage(role: .user, text: "eski bağlam")],
            activityGroups: [],
            followups: [SideExchange(question: "takip?", answer: "önceki")],
            question: "neredeyiz?",
            speedMode: .normal,
            mode: .build
        )

        let stream = try await runtime.answerSideQuestion(query)
        var text = ""
        for try await event in stream.events {
            if case .assistantTextDelta(let delta) = event {
                text += delta
            }
        }
        XCTAssertEqual(text, "Hello world")

        let recordedBody = await transport.lastBodyText()
        let body = try XCTUnwrap(recordedBody)
        XCTAssertTrue(body.contains("eski bağlam"), "Geçmiş taşınmalı")
        XCTAssertTrue(body.contains("takip?"), "Takip soru taşınmalı")
        XCTAssertTrue(body.contains("önceki"), "Takip cevap taşınmalı")
        XCTAssertTrue(body.contains("neredeyiz?"), "Soru taşınmalı")
    }

    // MARK: - Çerçeveleme

    func testSideQuestionTextCarriesQuestion() {
        let framed = OpenCodeProviderRuntime.sideQuestionText("neredeyiz?")
        XCTAssertTrue(framed.contains("neredeyiz?"))
    }

    // MARK: - Yardımcılar

    private static func configuration() -> SessionConfiguration {
        SessionConfiguration(
            providerID: ProviderID("stub-side"),
            modelID: ProviderModelID("stub/model"),
            variantID: nil
        )
    }

    private static func query() -> SideQuestionQuery {
        SideQuestionQuery(
            configuration: configuration(),
            historyMessages: [],
            activityGroups: [],
            followups: [],
            question: "soru?",
            speedMode: .normal,
            mode: .build
        )
    }

    private static func openCodeQuery() -> SideQuestionQuery {
        SideQuestionQuery(
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude/opus"),
                variantID: nil
            ),
            historyMessages: [ChatMessage(role: .user, text: "eski bağlam")],
            activityGroups: [],
            followups: [],
            question: "neredeyiz?",
            speedMode: .normal,
            mode: .build
        )
    }

    private static func waitForInactive(
        service: SideQuestionService
    ) async -> SideQuestionService.ActiveSideQuestion? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let current = service.active, current.phase != .streaming {
                return current
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return service.active
    }
}

// MARK: - Betikli genel stub

private struct QuestionGatedSideRuntime: ProviderRuntime {
    let id = ProviderID("stub-side")

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: id, displayName: "Stub", models: [])
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        throw ProviderRuntimeError.unsupported
    }

    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
        if query.question == "first" {
            try? await Task.sleep(for: .milliseconds(200))
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.assistantTextDelta("STALE"))
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        pair.continuation.yield(.assistantTextDelta("FRESH"))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        return ProviderStream(events: pair.stream)
    }
}

private struct ScriptedSideRuntime: ProviderRuntime {
    enum Script: Sendable {
        case answer([String])
        case failure(ProviderRuntimeError)
        case hang
    }

    let id = ProviderID("stub-side")
    let script: Script

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: id, displayName: "Stub", models: [])
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        throw ProviderRuntimeError.unsupported
    }

    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
        switch script {
        case .answer(let chunks):
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            for chunk in chunks {
                pair.continuation.yield(.assistantTextDelta(chunk))
            }
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        case .failure(let error):
            throw error
        case .hang:
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            return ProviderStream(
                events: pair.stream,
                cancellation: {
                    pair.continuation.finish(throwing: CancellationError())
                }
            )
        }
    }
}

// MARK: - OpenCode fakes

private enum SideOpenCodeCall: Equatable, Sendable {
    case createSession
    case prompt(sessionID: String, agent: String?, text: String)
    case abort(sessionID: String)
    case deleteSession(sessionID: String)
}

private enum SideOpenCodeReply: Equatable, Sendable {
    case replyPermission(requestID: String, reply: String)
    case rejectQuestion(requestID: String)
}

private actor SideFakeOpenCodeClient: OpenCodeClientProtocol {
    private let lines: AsyncThrowingStream<String, Error>
    private let remoteSessionID: String
    private let eventStreamError: (any Error)?
    private var calls: [SideOpenCodeCall] = []
    private var replies: [SideOpenCodeReply] = []

    init(
        lines: AsyncThrowingStream<String, Error>,
        remoteSessionID: String,
        eventStreamError: (any Error)? = nil
    ) {
        self.lines = lines
        self.remoteSessionID = remoteSessionID
        self.eventStreamError = eventStreamError
    }

    func recordedCalls() -> [SideOpenCodeCall] { calls }
    func recordedAgents() -> [String?] {
        calls.compactMap {
            if case .prompt(_, let agent, _) = $0 { return agent }
            return nil
        }
    }
    func recordedReplies() -> [SideOpenCodeReply] { replies }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: ProviderID("opencode"), displayName: "OpenCode", models: [])
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] { [:] }

    func setAPIKey(providerID: String, key: String, metadata: [String: String]) async throws {}

    func createSession() async throws -> String {
        calls.append(.createSession)
        return remoteSessionID
    }

    func deleteSession(sessionID: String) async throws {
        calls.append(.deleteSession(sessionID: sessionID))
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        calls.append(.prompt(sessionID: sessionID, agent: nil, text: Self.text(from: parts)))
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart],
        agent: String?
    ) async throws {
        calls.append(.prompt(sessionID: sessionID, agent: agent, text: Self.text(from: parts)))
    }

    func abort(sessionID: String) async throws {
        calls.append(.abort(sessionID: sessionID))
    }

    func eventStream() async throws -> OpenCodeLineStream {
        if let eventStreamError {
            throw eventStreamError
        }
        return OpenCodeLineStream(statusCode: 200, lines: lines)
    }

    func replyPermission(requestID: String, reply: String) async throws {
        replies.append(.replyPermission(requestID: requestID, reply: reply))
    }

    func rejectQuestion(requestID: String) async throws {
        replies.append(.rejectQuestion(requestID: requestID))
    }

    func sessionTodos(sessionID: String) async throws -> [AgentTodo] { [] }

    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus] { [:] }

    func addMCPServer(
        name: String,
        config: OpenCodeMCPServerConfig
    ) async throws -> [String: OpenCodeMCPServerStatus] { [:] }

    func disconnectMCPServer(name: String) async throws {}

    nonisolated static func text(from parts: [OpenCodePromptPart]) -> String {
        parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
    }
}

private struct SideStubServerManager: OpenCodeServerManaging {
    func status() async -> OpenCodeServerStatus { .stopped }

    func start(computerUse: ComputerUseConfiguration?) async throws -> OpenCodeServerConnection {
        throw ProviderRuntimeError.unavailable
    }

    func currentConnection() async -> OpenCodeServerConnection? {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:51180")!,
            username: "opencode",
            password: "server-password"
        )
    }

    func stop() async {}
}

// MARK: - OpenAI fakes

private struct SideStubCredentialStore: CredentialStore {
    let value: String?

    func contains(_ key: CredentialKey) throws -> Bool { value != nil }
    func read(_ key: CredentialKey) throws -> String? { value }
    func write(_ value: String, for key: CredentialKey) throws {}
    func delete(_ key: CredentialKey) throws {}
}

private actor SideFakeOpenAITransport: OpenAITransport {
    private let lines: AsyncThrowingStream<String, Error>
    private var bodyText: String?

    init(lines: AsyncThrowingStream<String, Error>) {
        self.lines = lines
    }

    func lastBodyText() -> String? { bodyText }

    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        OpenAIHTTPResponse(statusCode: 200, data: Data())
    }

    func stream(_ request: URLRequest) async throws -> OpenAILineStream {
        if let body = request.httpBody {
            bodyText = String(data: body, encoding: .utf8)
        }
        return OpenAILineStream(statusCode: 200, lines: lines)
    }
}

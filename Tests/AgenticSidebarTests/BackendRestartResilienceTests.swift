import Foundation
import XCTest

@testable import AgenticSidebar

final class BackendRestartResilienceTests: XCTestCase {
    func testStatusReportsStoppedWhenTheManagedProcessDied() async throws {
        let launcher = ScriptedOpenCodeProcessLauncher()
        let manager = makeManager(launcher: launcher)

        _ = try await manager.start(computerUse: nil)
        let handles = await launcher.handles()
        let handle = try XCTUnwrap(handles.first)
        await handle.setRunning(false)

        let status = await manager.status()
        XCTAssertEqual(status, .stopped)

        let connection = await manager.currentConnection()
        XCTAssertNil(connection)
    }

    func testStartRelaunchesAfterTheManagedProcessDied() async throws {
        let launcher = ScriptedOpenCodeProcessLauncher()
        let ports = IncrementingPortAllocator(start: 51200)
        let manager = makeManager(launcher: launcher, portAllocator: ports)

        let firstConnection = try await manager.start(computerUse: nil)
        let handles = await launcher.handles()
        let firstHandle = try XCTUnwrap(handles.first)
        await firstHandle.setRunning(false)

        let secondConnection = try await manager.start(computerUse: nil)

        let requests = await launcher.requests()
        XCTAssertEqual(requests.count, 2, "A dead child must be relaunched")
        XCTAssertNotEqual(
            firstConnection.baseURL,
            secondConnection.baseURL,
            "The relaunched server must get its own port"
        )
    }

    func testHealthFailureRetriesOnceOnAFreshPort() async throws {
        let launcher = ScriptedOpenCodeProcessLauncher()
        let ports = IncrementingPortAllocator(start: 51300)
        let manager = makeManager(
            launcher: launcher,
            healthChecker: ScriptedOpenCodeHealthChecker(
                results: [.failure(.startupFailure), .success("1.18.31")]
            ),
            portAllocator: ports
        )

        let connection = try await manager.start(computerUse: nil)

        let requests = await launcher.requests()
        XCTAssertEqual(requests.count, 2)
        let launchedPorts = requests.map { request -> String in
            guard let portIndex = request.arguments.firstIndex(of: "--port"),
                request.arguments.indices.contains(portIndex + 1)
            else {
                return "missing"
            }
            return request.arguments[portIndex + 1]
        }
        XCTAssertEqual(
            launchedPorts,
            ["51300", "51301"],
            "The retry must probe a fresh port"
        )
        XCTAssertEqual(connection.baseURL.absoluteString, "http://127.0.0.1:51301")

        let status = await manager.status()
        XCTAssertEqual(status, .running(version: "1.18.31", baseURL: connection.baseURL))
    }

    func testRuntimeForgetsRemoteSessionsWhenTheServerConnectionChanges() async throws {
        let serverManager = MutableConnectionServerManager(
            connection: makeConnection(port: 51400)
        )
        let client = RestartRecordingOpenCodeClient()
        let runtime = OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let sessionID = UUID()

        let firstStream = try await runtime.startStream(
            for: makeRequest(sessionID: sessionID)
        )
        await firstStream.cancel()

        await serverManager.setConnection(makeConnection(port: 51401))

        let secondStream = try await runtime.startStream(
            for: makeRequest(sessionID: sessionID)
        )
        await secondStream.cancel()

        let createdSessions = await client.createdSessions()
        XCTAssertEqual(
            createdSessions,
            ["ses_1", "ses_2"],
            "A restarted backend cannot know about sessions created by the previous server"
        )
    }

    func testRuntimeRecreatesARejectedRemoteSessionOnce() async throws {
        let serverManager = MutableConnectionServerManager(
            connection: makeConnection(port: 51402)
        )
        let client = RestartRecordingOpenCodeClient(
            promptErrors: [ProviderRuntimeError.unexpectedResponse]
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.startStream(
            for: makeRequest(sessionID: UUID())
        )
        await stream.cancel()

        let createdSessions = await client.createdSessions()
        let prompts = await client.prompts()
        let deletedSessions = await client.deletedSessions()

        // The fake names sessions by count, so the replacement reuses `ses_1`:
        // what matters is that the rejected orphan was deleted, not kept.
        XCTAssertEqual(createdSessions.count, 1)
        XCTAssertEqual(deletedSessions, ["ses_1"])
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts.first, prompts.last)
    }

    func testFailedFirstPromptDropsMappingSoNextTurnStartsFresh() async throws {
        let serverManager = MutableConnectionServerManager(
            connection: makeConnection(port: 51403)
        )
        let client = RestartRecordingOpenCodeClient(
            promptErrors: [ProviderRuntimeError.transport]
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let sessionID = UUID()

        do {
            _ = try await runtime.startStream(for: makeRequest(sessionID: sessionID))
            XCTFail("A failed first prompt must surface, not hang")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .transport)
        }

        let retryRequest = ProviderRequest(
            sessionID: sessionID,
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude/opus"),
                variantID: nil
            ),
            messages: [
                ChatMessage(role: .user, text: "Old question"),
                ChatMessage(role: .assistant, text: "Old answer"),
                ChatMessage(role: .user, text: "New question"),
            ],
            speedMode: .normal
        )
        let retry = try await runtime.startStream(for: retryRequest)
        await retry.cancel()

        let sessionsAfterRetry = await client.createdSessions()
        let deletionsAfterRetry = await client.deletedSessions()
        let retryPrompts = await client.prompts()
        // Same naming caveat as above: the recreated session reuses `ses_1`.
        XCTAssertEqual(sessionsAfterRetry.count, 1)
        XCTAssertEqual(deletionsAfterRetry, ["ses_1"])
        XCTAssertEqual(retryPrompts.count, 2)
        XCTAssertTrue(
            retryPrompts.last?.contains("Conversation history restored") ?? false,
            "The turn after a failed first prompt must carry the preamble again"
        )
    }

    func testRetryFailureAlsoDropsMappingSoNextTurnStartsFresh() async throws {
        let serverManager = MutableConnectionServerManager(
            connection: makeConnection(port: 51404)
        )
        let client = RestartRecordingOpenCodeClient(
            promptErrors: [ProviderRuntimeError.unexpectedResponse, ProviderRuntimeError.transport]
        )
        let runtime = OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )
        let sessionID = UUID()

        do {
            _ = try await runtime.startStream(for: makeRequest(sessionID: sessionID))
            XCTFail("A twice-failed prompt must surface, not hang")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .transport)
        }

        let deletions = await client.deletedSessions()
        XCTAssertEqual(
            deletions.count,
            2,
            "Both the rejected orphan and the failed retry must be deleted"
        )

        let retryRequest = ProviderRequest(
            sessionID: sessionID,
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude/opus"),
                variantID: nil
            ),
            messages: [
                ChatMessage(role: .user, text: "Old question"),
                ChatMessage(role: .assistant, text: "Old answer"),
                ChatMessage(role: .user, text: "New question"),
            ],
            speedMode: .normal
        )
        let retry = try await runtime.startStream(for: retryRequest)
        await retry.cancel()

        let secondRetryPrompts = await client.prompts()
        XCTAssertEqual(secondRetryPrompts.count, 3)
        XCTAssertTrue(
            secondRetryPrompts.last?.contains("Conversation history restored") ?? false,
            "The turn after a failed retry must carry the preamble again"
        )
    }

    func testPermissionDedupEvictsOldest() async throws {
        // 130 distinct requests overflow the 128-entry turn dedup; repeating
        // the evicted oldest must be answered again, not mistaken for a dupe.
        // `ses_1` is the fake's first created session (see its createSession).
        var lines: [String] = []
        for index in 0..<130 {
            lines.append(
                "data: {\"type\":\"permission.asked\",\"properties\":{\"sessionID\":\"ses_1\",\"id\":\"per_\(index)\",\"permission\":\"bash\",\"patterns\":[\"ls\"],\"always\":[]}}"
            )
        }
        lines.append(
            "data: {\"type\":\"permission.asked\",\"properties\":{\"sessionID\":\"ses_1\",\"id\":\"per_0\",\"permission\":\"bash\",\"patterns\":[\"ls\"],\"always\":[]}}"
        )
        lines.append("data: {\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_1\"}}")

        let serverManager = MutableConnectionServerManager(
            connection: makeConnection(port: 51405)
        )
        let client = RestartRecordingOpenCodeClient(streamLines: lines)
        let runtime = OpenCodeProviderRuntime(
            serverManager: serverManager,
            clientFactory: { _ in client },
            permissionHandler: { _ in .once },
            cancelPendingPermissions: nil
        )

        let stream = try await runtime.startStream(for: makeRequest(sessionID: UUID()))
        for try await _ in stream.events {}

        let deadline = ContinuousClock.now + .seconds(10)
        var replies: [String] = []
        while ContinuousClock.now < deadline {
            replies = await client.replies()
            if replies.count >= 131 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(replies.count, 131)
    }

    func testClientWithoutAgentSelectionRefusesReadOnlyPlan() async {
        let legacyClient = RestartRecordingOpenCodeClient()
        do {
            try await legacyClient.sendPromptAsync(
                sessionID: "ses_1",
                model: OpenCodeModelReference(providerID: "anthropic", modelID: "claude/opus"),
                variant: nil,
                parts: [.text("Inspect only")],
                agent: ManagedOpenCodeConfiguration.planAgentName
            )
            XCTFail("A client that cannot select the read-only agent must not submit the prompt")
        } catch {
            XCTAssertEqual(error as? ProviderRuntimeError, .unavailable)
        }
        let submitted = await legacyClient.prompts()
        XCTAssertTrue(submitted.isEmpty, "The unsafe fallback must never send a plan prompt")
    }

    private func makeManager(
        launcher: ScriptedOpenCodeProcessLauncher,
        healthChecker: any OpenCodeHealthChecking = ScriptedOpenCodeHealthChecker(
            results: Array(repeating: .success("1.18.31"), count: 4)
        ),
        portAllocator: any OpenCodePortAllocating = IncrementingPortAllocator(start: 51250)
    ) -> ManagedOpenCodeServerManager {
        ManagedOpenCodeServerManager(
            executableLocator: RestartStubExecutableLocator(),
            processLauncher: launcher,
            healthChecker: healthChecker,
            portAllocator: portAllocator,
            listenerVerifier: RestartStubListenerVerifier(),
            credentialStore: RestartInMemoryCredentialStore(),
            workingDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("opencode-restart-tests-\(UUID().uuidString)"),
            passwordGenerator: { "generated-password" }
        )
    }

    private func makeConnection(port: UInt16) -> OpenCodeServerConnection {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            username: "opencode",
            password: "server-password"
        )
    }

    private func makeRequest(sessionID: UUID) -> ProviderRequest {
        ProviderRequest(
            sessionID: sessionID,
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude/opus"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "Continue")],
            speedMode: .normal
        )
    }
}

/// The child in these tests is a stub with no socket of its own, so the port
/// ownership check is answered here.
private struct RestartStubListenerVerifier: OpenCodeListenerVerifying {
    func waitUntilProcessOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) async -> Bool {
        true
    }
}

private struct RestartStubExecutableLocator: OpenCodeExecutableLocating {
    func resolution() -> OpenCodeExecutableResolution {
        .found(URL(fileURLWithPath: "/opt/homebrew/bin/opencode"))
    }
}

private final class IncrementingPortAllocator: OpenCodePortAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var nextPort: UInt16

    init(start: UInt16) {
        self.nextPort = start
    }

    func allocate() throws -> UInt16 {
        lock.withLock {
            defer { nextPort += 1 }
            return nextPort
        }
    }
}

private final class ScriptedOpenCodeHealthChecker: OpenCodeHealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, ProviderRuntimeError>]

    init(results: [Result<String, ProviderRuntimeError>]) {
        self.results = results
    }

    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String {
        let next = lock.withLock { results.isEmpty ? nil : results.removeFirst() }

        guard let next else {
            throw ProviderRuntimeError.startupFailure
        }

        return try next.get()
    }
}

private actor InMemoryOpenCodeProcessHandle: OpenCodeProcessHandling {
    private var running: Bool
    private var terminations = 0

    init(running: Bool) {
        self.running = running
    }

    func setRunning(_ value: Bool) {
        running = value
    }

    func isRunning() async -> Bool {
        running
    }

    func processIdentifier() async -> Int32? {
        running ? 4242 : nil
    }

    func terminate() async {
        running = false
        terminations += 1
    }

    func terminationCount() -> Int {
        terminations
    }
}

private actor ScriptedOpenCodeProcessLauncher: OpenCodeProcessLaunching {
    private var recordedRequests: [OpenCodeProcessLaunchRequest] = []
    private var recordedHandles: [InMemoryOpenCodeProcessHandle] = []

    func launch(
        _ request: OpenCodeProcessLaunchRequest
    ) async throws -> any OpenCodeProcessHandling {
        recordedRequests.append(request)

        let handle = InMemoryOpenCodeProcessHandle(running: true)
        recordedHandles.append(handle)
        return handle
    }

    func requests() -> [OpenCodeProcessLaunchRequest] {
        recordedRequests
    }

    func handles() -> [InMemoryOpenCodeProcessHandle] {
        recordedHandles
    }
}

private actor MutableConnectionServerManager: OpenCodeServerManaging {
    private var connection: OpenCodeServerConnection?

    init(connection: OpenCodeServerConnection?) {
        self.connection = connection
    }

    func setConnection(_ connection: OpenCodeServerConnection?) {
        self.connection = connection
    }

    func status() async -> OpenCodeServerStatus {
        guard let connection else {
            return .stopped
        }
        return .running(version: "1.18.31", baseURL: connection.baseURL)
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

    func stop() async {
        connection = nil
    }
}

private actor RestartRecordingOpenCodeClient: OpenCodeClientProtocol {
    private var sessions: [String] = []
    private var recordedPrompts: [String] = []
    private var recordedDeletions: [String] = []
    private var recordedReplies: [String] = []
    private var promptErrors: [Error]
    private let streamLines: [String]

    init(promptErrors: [Error] = [], streamLines: [String] = []) {
        self.promptErrors = promptErrors
        self.streamLines = streamLines
    }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: ProviderID("opencode"), displayName: "OpenCode", models: [])
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] { [:] }

    func setAPIKey(
        providerID: String,
        key: String,
        metadata: [String: String]
    ) async throws {}

    func createSession() async throws -> String {
        let sessionID = "ses_\(sessions.count + 1)"
        sessions.append(sessionID)
        return sessionID
    }

    func deleteSession(sessionID: String) async throws {
        recordedDeletions.append(sessionID)
        sessions.removeAll { $0 == sessionID }
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        let text = parts.compactMap { part -> String? in
            if case .text(let str) = part { return str }
            return nil
        }.joined(separator: "\n")
        recordedPrompts.append(text)

        if !promptErrors.isEmpty {
            throw promptErrors.removeFirst()
        }
    }

    func abort(sessionID: String) async throws {}

    func replyPermission(requestID: String, reply: String) async throws {
        recordedReplies.append(requestID)
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
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        for line in streamLines {
            pair.continuation.yield(line)
        }
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    func createdSessions() -> [String] {
        sessions
    }

    func deletedSessions() -> [String] {
        recordedDeletions
    }

    func replies() -> [String] {
        recordedReplies
    }

    func prompts() -> [String] {
        recordedPrompts
    }
}

private final class RestartInMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String] = [:]

    func contains(_ key: CredentialKey) throws -> Bool {
        lock.withLock { values[key] != nil }
    }

    func read(_ key: CredentialKey) throws -> String? {
        lock.withLock { values[key] }
    }

    func write(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key] = value }
    }

    func delete(_ key: CredentialKey) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

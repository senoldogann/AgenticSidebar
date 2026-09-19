import Foundation
import Synchronization
import XCTest

@testable import AgenticSidebar

final class OpenCodeCodingAgentAdapterTests: XCTestCase {

    func testDistinctChatAndTaskRemoteSessions() async throws {
        let client = AdapterMockOpenCodeClient()
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/workspace/project-a")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let attemptID = UUID()
        let request = makeRequest(
            attemptID: attemptID,
            workspacePath: "/workspace/project-a",
            stage: .plan
        )

        let run = try await adapter.start(request: request)
        var events: [CodingAgentEvent] = []
        for await event in run.events {
            events.append(event)
        }

        let calls = await client.calls()
        let createdSessionCalls = calls.filter { $0 == .createSession }
        XCTAssertEqual(createdSessionCalls.count, 1)

        // Remote session created must belong solely to this attempt
        let remoteID = await adapter.remoteSessionID(for: attemptID)
        XCTAssertNotNil(remoteID)
        XCTAssertEqual(remoteID, "mock-session-1")
    }

    func testWrongWorkspaceRefusal() async throws {
        let client = AdapterMockOpenCodeClient()
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/managed/app/directory")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let config = SessionConfiguration(
            providerID: ProviderID("opencode"),
            modelID: ProviderModelID("anthropic/claude-3-5-sonnet"),
            variantID: nil
        )

        // Capabilities must not include workspaceWrite when server is not in the workspace
        let caps = await adapter.capabilities(configuration: config)
        XCTAssertFalse(
            caps.contains(.workspaceWrite),
            "workspaceWrite must not be advertised when server working directory does not match target workspace"
        )

        // Attempting implementation in an uncontained workspace must fail
        let request = makeRequest(
            attemptID: UUID(),
            workspacePath: "/isolated/worktree-1",
            stage: .implementation
        )

        do {
            _ = try await adapter.start(request: request)
            XCTFail("Must fail when backend working directory does not match requested workspace")
        } catch let error as CodingAgentAdapterError {
            guard case .workspaceNotContained(let expected, let actual) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertTrue(expected.contains("worktree-1"))
            XCTAssertEqual(actual, "/managed/app/directory")
        }

        let calls = await client.calls()
        XCTAssertFalse(calls.contains(.createSession), "Must not create a session on wrong workspace refusal")
    }

    func testWrongWorkspaceIsRefusedForEveryTaskStage() async throws {
        let client = AdapterMockOpenCodeClient()
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/managed/app/directory")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        for stage in TaskStage.allCases {
            let request = makeRequest(
                attemptID: UUID(),
                workspacePath: "/isolated/worktree-1",
                stage: stage
            )

            do {
                _ = try await adapter.start(request: request)
                XCTFail("Stage \(stage.rawValue) must refuse a backend rooted outside the owned workspace")
            } catch let error as CodingAgentAdapterError {
                guard case .workspaceNotContained(let expected, let actual) = error else {
                    return XCTFail("Unexpected error for stage \(stage.rawValue): \(error)")
                }
                XCTAssertEqual(expected, "/isolated/worktree-1")
                XCTAssertEqual(actual, "/managed/app/directory")
            }
        }

        let calls = await client.calls()
        XCTAssertFalse(calls.contains(.createSession), "Wrong-workspace refusal must happen before remote session creation")
    }

    func testChildPermissionAttribution() async throws {
        let taskSessionID = "task-session-root"
        let childSessionID = "child-subagent-session"

        let permID = "perm-req-42"
        let permissionHandled = Mutex<OpenCodePermissionRequest?>(nil)
        let handler: OpenCodeProviderRuntime.PermissionHandler = { req in
            permissionHandled.withLock { $0 = req }
            return .once
        }

        // SSE lines simulating child task spawning and permission request under the parent
        let lines = [
            "data: {\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"\(taskSessionID)\",\"part\":{\"id\":\"part-task-1\",\"type\":\"tool\",\"tool\":\"task\",\"state\":{\"status\":\"running\",\"input\":{},\"metadata\":{\"sessionId\":\"\(childSessionID)\"}}}}}",
            "data: {\"type\":\"permission.asked\",\"properties\":{\"id\":\"\(permID)\",\"sessionID\":\"\(childSessionID)\",\"permission\":\"bash\",\"patterns\":[\"git status\"],\"always\":[\"git status\"],\"metadata\":{\"detail\":\"git status\"}}}",
            "data: {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"\(taskSessionID)\",\"status\":{\"type\":\"idle\"}}}",
        ]

        let streamPair = AsyncThrowingStream<String, Error>.makeStream()
        for line in lines {
            streamPair.continuation.yield(line)
        }
        streamPair.continuation.finish()
        let lineStream = OpenCodeLineStream(statusCode: 200, lines: streamPair.stream)

        let client = AdapterMockOpenCodeClient(
            customSessionID: taskSessionID,
            eventStreams: [lineStream]
        )
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/workspace/project-a")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: handler,
            cancelPendingPermissions: nil
        )

        let attemptID = UUID()
        let request = makeRequest(
            attemptID: attemptID,
            workspacePath: "/workspace/project-a",
            stage: .implementation
        )

        let run = try await adapter.start(request: request)
        var approvalEvents: [CodingAgentEvent] = []
        for await event in run.events {
            if case .approvalRequested = event.kind {
                approvalEvents.append(event)
            }
        }

        XCTAssertEqual(approvalEvents.count, 1)
        if !approvalEvents.isEmpty, case .approvalRequested(let reqID, let tool, let params) = approvalEvents[0].kind {
            XCTAssertEqual(reqID, permID)
            XCTAssertEqual(tool, "bash")
            XCTAssertEqual(params["patterns"], "git status")
        }

        // Wait briefly for the handler task to process
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline && permissionHandled.withLock({ $0 == nil }) {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let handled = permissionHandled.withLock { $0 }
        XCTAssertNotNil(handled)
        XCTAssertEqual(handled?.appSessionID, attemptID)
        XCTAssertTrue(handled?.isDelegatedSession ?? false)
    }

    func testStreamInterruptionOnPrematureEOF() async throws {
        // Line stream that ends without session.status idle or completion
        let lines = [
            "data: {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"part-1\",\"type\":\"text\",\"text\":\"Thinking...\"}}}"
        ]

        let streamPair = AsyncThrowingStream<String, Error>.makeStream()
        for line in lines {
            streamPair.continuation.yield(line)
        }
        streamPair.continuation.finish()
        let lineStream = OpenCodeLineStream(statusCode: 200, lines: streamPair.stream)

        let client = AdapterMockOpenCodeClient(
            eventStreams: [lineStream]
        )
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/workspace/project-a")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let request = makeRequest(
            attemptID: UUID(),
            workspacePath: "/workspace/project-a",
            stage: .plan
        )

        let run = try await adapter.start(request: request)
        var events: [CodingAgentEvent] = []
        for await event in run.events {
            events.append(event)
        }

        XCTAssertFalse(
            CodingAgentRun.isTerminatedSuccessfully(events: events),
            "Premature EOF without terminal completion event must not be treated as success"
        )
        XCTAssertTrue(
            events.contains {
                if case .terminalError = $0.kind { return true }
                return false
            },
            "Premature EOF must emit terminalError"
        )
    }

    func testCancelAndReleaseWithoutTouchingAnotherSession() async throws {
        let client = AdapterMockOpenCodeClient()
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/workspace/project-a")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: nil,
            cancelPendingPermissions: nil
        )

        let attemptA = UUID()
        let attemptB = UUID()

        let reqA = makeRequest(attemptID: attemptA, workspacePath: "/workspace/project-a", stage: .plan)
        let reqB = makeRequest(attemptID: attemptB, workspacePath: "/workspace/project-a", stage: .plan)

        let runA = try await adapter.start(request: reqA)
        let runB = try await adapter.start(request: reqB)

        _ = await runA.events.first { _ in true }
        _ = await runB.events.first { _ in true }

        let remoteA = await adapter.remoteSessionID(for: attemptA)
        let remoteB = await adapter.remoteSessionID(for: attemptB)
        XCTAssertNotNil(remoteA)
        XCTAssertNotNil(remoteB)
        XCTAssertNotEqual(remoteA, remoteB)

        // Cancel run A
        await runA.cancel()
        let abortCalls = await client.calls().filter {
            if case .abort(let id) = $0 { return id == remoteA }
            return false
        }
        XCTAssertEqual(abortCalls.count, 1)

        // Release attempt A
        await adapter.release(attemptID: attemptA)
        let deleteCallsA = await client.calls().filter {
            if case .deleteSession(let id) = $0 { return id == remoteA }
            return false
        }
        XCTAssertEqual(deleteCallsA.count, 1)

        // Remote B must NOT have been deleted or aborted
        let deleteCallsB = await client.calls().filter {
            if case .deleteSession(let id) = $0 { return id == remoteB }
            return false
        }
        XCTAssertEqual(deleteCallsB.count, 0)
    }

    func testCancelledAttemptDoesNotSendLatePermissionApproval() async throws {
        let permID = "perm-late-approval"
        let handlerStarted = Mutex(false)
        let gate = AsyncStream<Void>.makeStream()
        let handler: OpenCodeProviderRuntime.PermissionHandler = { _ in
            handlerStarted.withLock { $0 = true }
            _ = await gate.stream.first { _ in true }
            return .once
        }

        let streamPair = AsyncThrowingStream<String, Error>.makeStream()
        streamPair.continuation.yield(
            "data: {\"type\":\"permission.asked\",\"properties\":{\"id\":\"\(permID)\",\"sessionID\":\"task-session-root\",\"permission\":\"bash\",\"patterns\":[\"git status\"],\"always\":[\"git status\"],\"metadata\":{\"detail\":\"git status\"}}}"
        )
        let lineStream = OpenCodeLineStream(statusCode: 200, lines: streamPair.stream)

        let client = AdapterMockOpenCodeClient(
            customSessionID: "task-session-root",
            eventStreams: [lineStream]
        )
        let manager = AdapterMockServerManager(
            workingDirectory: URL(fileURLWithPath: "/workspace/project-a")
        )
        let adapter = OpenCodeCodingAgentAdapter(
            serverManager: manager,
            clientFactory: { _ in client },
            permissionHandler: handler,
            cancelPendingPermissions: nil
        )

        let attemptID = UUID()
        let request = makeRequest(
            attemptID: attemptID,
            workspacePath: "/workspace/project-a",
            stage: .implementation
        )
        let run = try await adapter.start(request: request)

        var sawApproval = false
        for await event in run.events {
            if case .approvalRequested(let requestID, _, _) = event.kind, requestID == permID {
                sawApproval = true
                break
            }
        }
        XCTAssertTrue(sawApproval)

        let handlerDeadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < handlerDeadline && !handlerStarted.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(handlerStarted.withLock { $0 })

        await run.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()
        try? await Task.sleep(for: .milliseconds(50))

        let lateReplies = await client.calls().filter {
            if case .replyPermission(let requestID, let reply) = $0 {
                return requestID == permID && reply == OpenCodePermissionReply.once.rawValue
            }
            return false
        }
        XCTAssertTrue(
            lateReplies.isEmpty,
            "A cancelled attempt must not send an approval after its permission handler resolves"
        )
    }

    // MARK: - Helpers

    private func makeRequest(
        attemptID: UUID,
        workspacePath: String,
        stage: TaskStage
    ) -> CodingAgentExecutionRequest {
        CodingAgentExecutionRequest(
            taskID: UUID(),
            attemptID: attemptID,
            generation: 1,
            role: .developer,
            configuration: SessionConfiguration(
                providerID: ProviderID("opencode"),
                modelID: ProviderModelID("anthropic/claude-3-5-sonnet"),
                variantID: nil
            ),
            objective: "Implement login view",
            acceptanceCriteria: [
                CodingAcceptanceCriterion(
                    taskID: UUID(),
                    description: "Unit tests pass"
                )
            ],
            workspacePath: workspacePath,
            stage: stage
        )
    }
}

// MARK: - Adapter Mocks

private enum AdapterMockCall: Equatable, Sendable {
    case createSession
    case deleteSession(String)
    case abort(String)
    case replyPermission(requestID: String, reply: String)
    case sendPrompt(sessionID: String, model: String)
    case eventStream
}

private actor AdapterMockOpenCodeClient: OpenCodeClientProtocol {
    private var sessionCounter = 0
    private let customSessionID: String?
    private var streams: [OpenCodeLineStream]
    private var recordedCalls: [AdapterMockCall] = []

    init(customSessionID: String? = nil, eventStreams: [OpenCodeLineStream] = []) {
        self.customSessionID = customSessionID
        self.streams = eventStreams
    }

    func calls() -> [AdapterMockCall] {
        recordedCalls
    }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            id: ProviderID("opencode"),
            displayName: "OpenCode",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("anthropic/claude-3-5-sonnet"),
                    displayName: "Anthropic Claude 3.5 Sonnet",
                    variants: [],
                    contextLimit: 200_000
                )
            ]
        )
    }

    func authMethods() async throws -> [String: [OpenCodeAuthMethod]] { [:] }
    func setAPIKey(providerID: String, key: String, metadata: [String: String]) async throws {}

    func createSession() async throws -> String {
        recordedCalls.append(.createSession)
        if let customSessionID {
            return customSessionID
        }
        sessionCounter += 1
        return "mock-session-\(sessionCounter)"
    }

    func deleteSession(sessionID: String) async throws {
        recordedCalls.append(.deleteSession(sessionID))
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart]
    ) async throws {
        recordedCalls.append(.sendPrompt(sessionID: sessionID, model: model.flattenedID.rawValue))
    }

    func sendPromptAsync(
        sessionID: String,
        model: OpenCodeModelReference,
        variant: String?,
        parts: [OpenCodePromptPart],
        agent: String?
    ) async throws {
        recordedCalls.append(.sendPrompt(sessionID: sessionID, model: model.flattenedID.rawValue))
    }

    func abort(sessionID: String) async throws {
        recordedCalls.append(.abort(sessionID))
    }

    func eventStream() async throws -> OpenCodeLineStream {
        recordedCalls.append(.eventStream)
        if !streams.isEmpty {
            return streams.removeFirst()
        }
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.yield(
            "data: {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"test\",\"status\":{\"type\":\"idle\"}}}"
        )
        pair.continuation.finish()
        return OpenCodeLineStream(statusCode: 200, lines: pair.stream)
    }

    func replyPermission(requestID: String, reply: String) async throws {
        recordedCalls.append(.replyPermission(requestID: requestID, reply: reply))
    }
    func sessionTodos(sessionID: String) async throws -> [AgentTodo] { [] }
    func mcpServerStatuses() async throws -> [String: OpenCodeMCPServerStatus] { [:] }
    func addMCPServer(name: String, config: OpenCodeMCPServerConfig) async throws -> [String: OpenCodeMCPServerStatus] { [:] }
    func disconnectMCPServer(name: String) async throws {}
}

private struct AdapterMockServerManager: OpenCodeServerManaging {
    let workingDirectory: URL?

    func status() async -> OpenCodeServerStatus {
        .running(version: "1.18.31", baseURL: URL(string: "http://127.0.0.1:51180")!)
    }

    func start(computerUse: ComputerUseConfiguration?) async throws -> OpenCodeServerConnection {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:51180")!,
            username: "opencode",
            password: "test-password"
        )
    }

    func currentConnection() async -> OpenCodeServerConnection? {
        OpenCodeServerConnection(
            baseURL: URL(string: "http://127.0.0.1:51180")!,
            username: "opencode",
            password: "test-password"
        )
    }

    func stop() async {}

    func workingDirectory() async -> URL? {
        workingDirectory
    }
}

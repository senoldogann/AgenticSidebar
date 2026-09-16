import Foundation
import Observation
import XCTest
@testable import AgenticSidebar

@MainActor
final class MultiSessionTests: XCTestCase {
    func testCreateSessionStartsEmptyAndInheritsTheSelectedConfiguration() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime(), makeBetaRuntime()])
        await service.refreshCapabilities()
        XCTAssertEqual(service.state.configuration?.providerID, ProviderID("alpha"))

        try service.selectProvider(ProviderID("beta"))
        let inherited = service.state.configuration

        let newSessionID = service.createSession()

        XCTAssertEqual(service.activeSessionID, newSessionID)
        XCTAssertTrue(service.state.messages.isEmpty)
        XCTAssertEqual(service.state.configuration?.providerID, ProviderID("beta"))
        XCTAssertEqual(service.state.configuration, inherited)
        XCTAssertEqual(service.sessions.count, 2)
        XCTAssertEqual(service.sessions.first?.id, newSessionID, "Newest session comes first")
    }

    func testCreateSessionBeforeCapabilitiesLoadKeepsTheInheritedConfiguration() throws {
        let inherited = SessionConfiguration(
            providerID: ProviderID("beta"),
            modelID: ProviderModelID("beta-1"),
            variantID: nil
        )
        let service = AgentSessionService(
            runtimes: [makeAlphaRuntime(), makeBetaRuntime()],
            state: AgentSessionState(configuration: inherited)
        )

        service.createSession()

        XCTAssertEqual(service.state.configuration, inherited)
    }

    func testSelectSessionSwitchesTheActiveTranscript() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let firstID = service.activeSessionID
        let turn = try XCTUnwrap(service.submit("first conversation"))
        await turn.value

        let secondID = service.createSession()
        service.selectSession(firstID)

        XCTAssertEqual(service.activeSessionID, firstID)
        XCTAssertEqual(service.state.messages.first?.text, "first conversation")

        service.selectSession(secondID)
        XCTAssertTrue(service.state.messages.isEmpty)
    }

    func testBackgroundSessionKeepsStreamingWhileAnotherSessionIsActive() async throws {
        let gate = StreamGate()
        let service = AgentSessionService(
            runtimes: [makeGatedRuntime(gate: gate)]
        )
        await service.refreshCapabilities()

        let backgroundID = service.activeSessionID
        let backgroundSession = try XCTUnwrap(
            service.sessions.first { $0.id == backgroundID }
        )
        let turn = try XCTUnwrap(service.submit("start something long"))
        XCTAssertTrue(backgroundSession.isBusy)

        // Switching conversations must not interrupt the running turn.
        let foregroundID = service.createSession()
        XCTAssertEqual(service.activeSessionID, foregroundID)
        XCTAssertTrue(backgroundSession.isBusy)
        XCTAssertFalse(service.isBusy, "The new session is idle")
        XCTAssertTrue(service.canSubmit, "A busy background session must not block input")

        await gate.open()
        await turn.value

        XCTAssertEqual(backgroundSession.state.status, .completed)
        XCTAssertEqual(
            backgroundSession.state.messages.map(\.text),
            ["start something long", "working"]
        )
        XCTAssertTrue(service.state.messages.isEmpty, "The foreground session stayed untouched")
    }

    func testDeletingAStreamingSessionStopsItsTurnAndKeepsOneSession() async throws {
        let gate = StreamGate()
        let service = AgentSessionService(runtimes: [makeGatedRuntime(gate: gate)])
        await service.refreshCapabilities()

        let turn = try XCTUnwrap(service.submit("keep working"))
        let removedID = service.activeSessionID
        let removedSession = try XCTUnwrap(service.sessions.first { $0.id == removedID })

        service.deleteSession(removedID)

        XCTAssertEqual(service.sessions.count, 1)
        XCTAssertNotEqual(service.activeSessionID, removedID)
        XCTAssertTrue(service.state.messages.isEmpty)
        let wasCancelled = await waitUntil { removedSession.state.status == .cancelled }
        XCTAssertTrue(wasCancelled, "Deleting a session must cancel its turn")

        await turn.value
    }

    func testDeletingTheOnlySessionReplacesItWithAFreshOne() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let onlyID = service.activeSessionID
        service.deleteSession(onlyID)

        XCTAssertEqual(service.sessions.count, 1)
        XCTAssertNotEqual(service.activeSessionID, onlyID)
        XCTAssertTrue(service.state.messages.isEmpty)
        XCTAssertEqual(
            service.state.configuration?.providerID,
            ProviderID("alpha"),
            "A replacement session keeps the app usable"
        )
    }

    func testConfigurationIsIndependentPerSession() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime(), makeBetaRuntime()])
        await service.refreshCapabilities()

        let firstID = service.activeSessionID
        try service.selectProvider(ProviderID("beta"))

        let secondID = service.createSession()
        try service.selectProvider(ProviderID("alpha"))

        service.selectSession(firstID)
        XCTAssertEqual(service.state.configuration?.providerID, ProviderID("beta"))

        service.selectSession(secondID)
        XCTAssertEqual(service.state.configuration?.providerID, ProviderID("alpha"))
    }

    func testSessionListReportsTitlesAndBusyState() async throws {
        let gate = StreamGate()
        let service = AgentSessionService(runtimes: [makeGatedRuntime(gate: gate)])
        await service.refreshCapabilities()

        let turn = try XCTUnwrap(service.submit("Explain the build failure"))
        let list = service.sessionList

        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "Explain the build failure")
        XCTAssertTrue(list[0].isBusy)
        XCTAssertEqual(list[0].id, service.activeSessionID)

        await gate.open()
        await turn.value

        XCTAssertFalse(service.sessionList[0].isBusy)
        XCTAssertNotNil(service.sessionList[0].completedAt)
        XCTAssertNotNil(service.sessionList[0].lastMessageAt)
    }

    func testTitleFallsBackToNewSessionAndTruncatesLongPrompts() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        XCTAssertEqual(service.activeSessionTitle, "New session")

        let longPrompt = String(repeating: "a", count: 200)
        let turn = try XCTUnwrap(service.submit(longPrompt + "\nsecond line"))
        await turn.value

        XCTAssertEqual(service.activeSessionTitle.count, 61)
        XCTAssertTrue(service.activeSessionTitle.hasSuffix("…"))
    }

    func testOverlongTranscriptIsTrimmedAndReportedToTheUser() async throws {
        let recorder = RequestRecorder()
        let runtime = TestProviderRuntime(
            id: ProviderID("alpha"),
            displayName: "Alpha",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("alpha-1"),
                    displayName: "Alpha 1",
                    variants: []
                )
            ],
            streamFactory: { request in
                await recorder.record(request)
                return ProviderStream(
                    events: AsyncThrowingStream { continuation in
                        continuation.yield(.completed)
                        continuation.finish()
                    }
                )
            }
        )

        let session = AgentSession(
            runtimes: [runtime],
            budget: TranscriptBudget(characterBudget: 1_000)
        )
        session.applyCapabilities(
            [runtime.capabilitySet],
            normalizeConfiguration: true
        )

        for index in 0..<10 {
            session.state.messages.append(
                ChatMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: String(repeating: "x", count: 400)
                )
            )
        }

        let task = try XCTUnwrap(session.submit("final question"))
        await task.value

        let recordedRequest = await recorder.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertLessThan(request.messages.count, 11)
        XCTAssertEqual(request.messages.last?.text, "final question")
        XCTAssertEqual(
            session.state.notice,
            .transcriptTrimmed(droppedMessageCount: 11 - request.messages.count)
        )
        XCTAssertEqual(
            session.state.messages.count,
            11,
            "Trimming only affects the request, never the stored transcript"
        )
    }

    func testShortTranscriptSendsEverythingWithoutANotice() async throws {
        let recorder = RequestRecorder()
        let runtime = TestProviderRuntime(
            id: ProviderID("alpha"),
            displayName: "Alpha",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("alpha-1"),
                    displayName: "Alpha 1",
                    variants: []
                )
            ],
            streamFactory: { request in
                await recorder.record(request)
                return ProviderStream(
                    events: AsyncThrowingStream { continuation in
                        continuation.yield(.completed)
                        continuation.finish()
                    }
                )
            }
        )

        let session = AgentSession(runtimes: [runtime])
        session.applyCapabilities([runtime.capabilitySet], normalizeConfiguration: true)

        let task = try XCTUnwrap(session.submit("hello"))
        await task.value

        let recordedRequest = await recorder.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.messages.map(\.text), ["hello"])
        XCTAssertNil(session.state.notice)
    }

    func testSessionStateObservationFiresOnMutations() async throws {
        let runtime = makeAlphaRuntime()
        let session = AgentSession(runtimes: [runtime])
        session.applyCapabilities([runtime.capabilitySet], normalizeConfiguration: true)

        let didChangeState = FlagBox()
        withObservationTracking {
            _ = session.state.messages.count
        } onChange: {
            didChangeState.value = true
        }

        let task = try XCTUnwrap(session.submit("observe me"))
        await task.value

        XCTAssertTrue(didChangeState.value, "Observation must trigger when a message is submitted")
    }

    func testModelSelectionTriggersObservation() throws {
        let runtime = makeAlphaRuntime()
        let session = AgentSession(runtimes: [runtime])
        let newModel = ProviderModelCapability(
            id: ProviderModelID("alpha-2"),
            displayName: "Alpha 2",
            variants: []
        )
        let providerWithTwoModels = ProviderCapabilities(
            id: ProviderID("alpha"),
            displayName: "Alpha",
            models: [runtime.capabilitySet.models[0], newModel]
        )
        session.applyCapabilities([providerWithTwoModels], normalizeConfiguration: true)

        let didChangeConfig = FlagBox()
        withObservationTracking {
            _ = session.state.configuration?.modelID
        } onChange: {
            didChangeConfig.value = true
        }

        try session.selectModel(ProviderModelID("alpha-2"))

        XCTAssertTrue(didChangeConfig.value, "Observation must trigger when a model is selected")
        XCTAssertEqual(session.state.configuration?.modelID, ProviderModelID("alpha-2"))
    }

    func testRenameSessionSetsCustomTitleAndEmptyReturnsToAutomatic() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let turn = try XCTUnwrap(service.submit("hello world"))
        await turn.value
        let id = service.activeSessionID

        service.renameSession(id, to: "  My custom name  ")
        XCTAssertEqual(service.sessionList.first?.customTitle, "My custom name")
        XCTAssertEqual(service.sessionList.first?.displayTitle, "My custom name")
        XCTAssertEqual(service.activeSessionTitle, "My custom name")

        service.renameSession(id, to: "   ")
        XCTAssertNil(service.sessionList.first?.customTitle)
        XCTAssertEqual(service.sessionList.first?.displayTitle, "hello world")
    }

    func testRenameTruncatesTo120Characters() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let id = service.activeSessionID
        service.renameSession(id, to: String(repeating: "x", count: 200))
        XCTAssertEqual(service.sessionList.first?.customTitle?.count, 120)
    }

    func testPinAndUnpinSession() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let id = service.activeSessionID
        XCTAssertFalse(service.sessionList.first?.isPinned ?? true)

        service.setSessionPinned(id, pinned: true)
        XCTAssertTrue(service.sessionList.first?.isPinned ?? false)

        service.toggleSessionPin(id)
        XCTAssertFalse(service.sessionList.first?.isPinned ?? true)
    }

    func testDeleteSessionsRemovesManyAndKeepsActiveInvariant() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let firstID = service.activeSessionID
        let secondID = service.createSession()
        let thirdID = service.createSession()
        XCTAssertEqual(service.sessions.count, 3)

        service.deleteSessions([firstID, secondID])
        XCTAssertEqual(service.sessions.count, 1)
        XCTAssertEqual(service.activeSessionID, thirdID)
    }

    func testDeleteSessionsWithAllSessionsLeavesOneEmptyReplacement() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let ids = Set(service.sessions.map(\.id))
        service.deleteSessions(ids)

        XCTAssertEqual(service.sessions.count, 1)
        XCTAssertTrue(service.state.messages.isEmpty)
    }

    func testDeleteSessionsWithEmptySetDoesNothing() async throws {
        let service = AgentSessionService(runtimes: [makeAlphaRuntime()])
        await service.refreshCapabilities()

        let count = service.sessions.count
        service.deleteSessions([])
        XCTAssertEqual(service.sessions.count, count)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return false
    }
}

private func makeAlphaRuntime() -> TestProviderRuntime {
    TestProviderRuntime(
        id: ProviderID("alpha"),
        displayName: "Alpha",
        models: [
            ProviderModelCapability(
                id: ProviderModelID("alpha-1"),
                displayName: "Alpha 1",
                variants: []
            )
        ]
    )
}

private func makeBetaRuntime() -> TestProviderRuntime {
    TestProviderRuntime(
        id: ProviderID("beta"),
        displayName: "Beta",
        models: [
            ProviderModelCapability(
                id: ProviderModelID("beta-1"),
                displayName: "Beta 1",
                variants: []
            )
        ]
    )
}

/// Streams one delta and then waits, so a test can hold a turn open.
private func makeGatedRuntime(gate: StreamGate) -> TestProviderRuntime {
    TestProviderRuntime(
        id: ProviderID("alpha"),
        displayName: "Alpha",
        models: [
            ProviderModelCapability(
                id: ProviderModelID("alpha-1"),
                displayName: "Alpha 1",
                variants: []
            )
        ],
        streamFactory: { _ in
            ProviderStream(
                events: AsyncThrowingStream { continuation in
                    let producer = Task {
                        continuation.yield(.assistantTextDelta("working"))
                        await gate.wait()
                        continuation.yield(.completed)
                        continuation.finish()
                    }

                    continuation.onTermination = { _ in
                        producer.cancel()
                    }
                }
            )
        }
    )
}

private actor RequestRecorder {
    private var requests: [ProviderRequest] = []

    func record(_ request: ProviderRequest) {
        requests.append(request)
    }

    var lastRequest: ProviderRequest? {
        requests.last
    }
}

private actor StreamGate {
    private var isOpen = false

    func open() {
        isOpen = true
    }

    func wait() async {
        while !isOpen {
            if Task.isCancelled {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class FlagBox: @unchecked Sendable {
    var value = false
}


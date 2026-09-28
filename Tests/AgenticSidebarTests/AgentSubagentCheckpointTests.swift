import Foundation
import XCTest

@testable import AgenticSidebar

/// Alt ajan listesi/iptali ve tur başı geri sarma.
///
/// Çıta: liste zaman çizelgesinden türetilir, çalışan kayıt turu iptal eder,
/// her tur başı kaydı alınır, meşgul oturum geri sarılmaz.
@MainActor
final class AgentSubagentCheckpointTests: XCTestCase {
    func testSubagentsListedFromTimeline() {
        let finished = AgentActivity(
            id: ProviderActivityID("sub-1"),
            kind: .subagent,
            phase: .completed,
            title: "Explore",
            detail: "ara adım",
            output: "RAPOR",
            startedAt: Date(),
            completedAt: Date()
        )
        let tool = AgentActivity(
            id: ProviderActivityID("read-1"),
            kind: .read,
            phase: .completed
        )
        var state = AgentSessionState()
        state.activityGroups = [
            AgentTurnActivityGroup(
                id: UUID(),
                anchorMessageID: UUID(),
                activities: [tool, finished],
                turnID: UUID()
            )
        ]
        let session = AgentSession(runtimes: [], state: state)

        let listed = session.subagents
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.title, "Explore")
        XCTAssertEqual(listed.first?.report, "RAPOR")
        XCTAssertFalse(listed.first?.isRunning ?? true)
    }

    func testCancelFinishedSubagentDoesNothing() async {
        let finished = AgentActivity(
            id: ProviderActivityID("sub-1"),
            kind: .subagent,
            phase: .completed
        )
        var state = AgentSessionState()
        state.activityGroups = [
            AgentTurnActivityGroup(id: UUID(), anchorMessageID: UUID(), activities: [finished])
        ]
        let session = AgentSession(runtimes: [], state: state)

        let cancelled = await session.cancelSubagent(ProviderActivityID("sub-1"))
        XCTAssertFalse(cancelled)
        let unknown = await session.cancelSubagent(ProviderActivityID("yok"))
        XCTAssertFalse(unknown)
    }

    func testCancelRunningSubagentCancelsTurn() async throws {
        let gate = StreamGate()
        let activityID = ProviderActivityID("sub-live")
        let session = makeSession { _ in
            ProviderStream(
                events: AsyncThrowingStream { continuation in
                    let producer = Task {
                        continuation.yield(
                            .activityStarted(
                                ProviderActivityDescriptor(id: activityID, kind: .subagent)
                            )
                        )
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

        let turn = try XCTUnwrap(session.submit("Hi"))
        let running = await waitUntil { session.subagents.first?.isRunning == true }
        XCTAssertTrue(running)

        let cancelled = await session.cancelSubagent(activityID)
        XCTAssertTrue(cancelled)
        await turn.value
        let settled = await waitUntil { !session.isBusy }
        XCTAssertTrue(settled)
        XCTAssertEqual(session.state.status, .cancelled)
        await gate.open()
    }

    func testTurnRecordsCheckpointAndRewindRestores() async throws {
        let session = makeSession { _ in
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.assistantTextDelta("selam"))
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }

        let turn = try XCTUnwrap(session.submit("Hi"))
        await turn.value
        let settled = await waitUntil { !session.isBusy }
        XCTAssertTrue(settled)
        XCTAssertEqual(session.checkpoints.count, 1)
        XCTAssertNil(session.checkpoints.first?.throughMessageID)
        XCTAssertEqual(session.state.messages.count, 2)

        XCTAssertTrue(session.rewind(to: session.checkpoints.first!.id))
        XCTAssertTrue(session.state.messages.isEmpty)
        XCTAssertEqual(session.state.status, .idle)
        XCTAssertNil(session.lastTurnUsage)
    }

    func testRewindRefusesWhileBusyAndUnknownID() async throws {
        let gate = StreamGate()
        let session = makeSession { _ in
            ProviderStream(
                events: AsyncThrowingStream { continuation in
                    let producer = Task {
                        continuation.yield(.assistantTextDelta("çalışıyor"))
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

        let turn = try XCTUnwrap(session.submit("Hi"))
        let busy = await waitUntil { session.isBusy }
        XCTAssertTrue(busy)
        XCTAssertFalse(session.rewind(to: UUID()))
        if let checkpointID = session.checkpoints.first?.id {
            XCTAssertFalse(session.rewind(to: checkpointID))
        }
        await gate.open()
        await turn.value
        let settled = await waitUntil { !session.isBusy }
        XCTAssertTrue(settled)
        XCTAssertFalse(session.rewind(to: UUID()))
    }

    func testCheckpointKeepsNotedHead() async throws {
        let session = makeSession { _ in
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }
        session.noteRepositoryHead("abcdef0123456789abcdef0123456789abcdef01")

        let turn = try XCTUnwrap(session.submit("Hi"))
        await turn.value
        let settled = await waitUntil { !session.isBusy }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            session.checkpoints.first?.gitCommitSHA,
            "abcdef0123456789abcdef0123456789abcdef01"
        )

        session.noteRepositoryHead("   ")
        let second = try XCTUnwrap(session.submit("tekrar"))
        await second.value
        let settledAgain = await waitUntil { !session.isBusy }
        XCTAssertTrue(settledAgain)
        XCTAssertNil(session.checkpoints.last?.gitCommitSHA)
    }

    func testHeadSHAReportsNilOutsideRepository() throws {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw XCTSkip("git bulunamadı")
        }
        let runner = GitCommandRunner(executableDirectory: URL(fileURLWithPath: "/usr/bin"), maxOutputBytes: 4_096)
        let outside = FileManager.default.temporaryDirectory
        XCTAssertNil(SessionCheckpointGit.headSHA(runner: runner, directory: outside))
    }

    func testServiceRewindAndSubagentForwarding() async throws {
        let service = AgentSessionService(runtimes: [makeCompletingRuntime()])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))
        await task.value
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
        XCTAssertEqual(service.checkpoints(for: service.activeSessionID).count, 1)
        XCTAssertTrue(service.subagents(for: service.activeSessionID).isEmpty)
        XCTAssertTrue(service.subagents(for: UUID()).isEmpty)

        let unknownCancel = await service.cancelSubagent(
            sessionID: UUID(),
            activityID: ProviderActivityID("yok")
        )
        XCTAssertFalse(unknownCancel)
        XCTAssertFalse(service.rewind(sessionID: UUID(), to: UUID()))

        let checkpointID = try XCTUnwrap(service.checkpoints(for: service.activeSessionID).first?.id)
        XCTAssertTrue(service.rewindActiveSession(to: checkpointID))
        XCTAssertTrue(service.state.messages.isEmpty)
    }

    // MARK: - Yardımcılar

    private func makeSession(
        streamFactory: @escaping @Sendable (ProviderRequest) async throws -> ProviderStream
    ) -> AgentSession {
        AgentSession(
            runtimes: [
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
                    streamFactory: streamFactory
                )
            ],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("alpha"),
                    modelID: ProviderModelID("alpha-1"),
                    variantID: nil
                )
            )
        )
    }

    private func makeCompletingRuntime() -> TestProviderRuntime {
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
                let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
                pair.continuation.yield(.assistantTextDelta("tamam"))
                pair.continuation.yield(.completed)
                pair.continuation.finish()
                return ProviderStream(events: pair.stream)
            }
        )
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
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

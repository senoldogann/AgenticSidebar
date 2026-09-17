import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class AgentModeTests: XCTestCase {
    func testPlanModeIsReadOnlyAndNamesThePlanFence() throws {
        let instruction = try XCTUnwrap(AgentMode.plan.instruction)

        XCTAssertTrue(instruction.contains("PLAN MODE"))
        XCTAssertTrue(
            instruction.lowercased().contains("do not create"),
            "The instruction has to forbid writing, or Plan mode is only a label"
        )
        XCTAssertTrue(
            instruction.contains("```\(AgentMode.planFenceLanguage)"),
            "The model must be told the exact fence the renderer turns into a document"
        )
        XCTAssertTrue(instruction.contains("approve"))
        XCTAssertNil(
            AgentMode.build.instruction,
            "Build is the provider's own default workflow and adds no instruction"
        )
    }

    func testModeInstructionComposesWithSpeedInstruction() throws {
        XCTAssertNil(AgentMode.build.instructions(speedMode: .normal))

        let fast = try XCTUnwrap(AgentMode.build.instructions(speedMode: .fast))
        XCTAssertTrue(fast.contains("FAST MODE"))

        let planAndFast = try XCTUnwrap(
            AgentMode.plan.instructions(speedMode: .fast)
        )
        let modeRange = try XCTUnwrap(planAndFast.range(of: "PLAN MODE"))
        let speedRange = try XCTUnwrap(planAndFast.range(of: "FAST MODE"))
        XCTAssertLessThan(
            modeRange.lowerBound,
            speedRange.lowerBound,
            "The agent mode is the stronger instruction, so it comes first"
        )
    }

    func testOpenAISendsPlanModeAsASystemInstructionAndOmitsItForBuild() throws {
        let planRequest = makeProviderRequest(mode: .plan)
        let planBody = try bodyJSON(
            from: OpenAIResponsesRequest.make(
                baseURL: URL(string: "https://example.test/v1")!,
                apiKey: "test-key",
                providerRequest: planRequest
            )
        )
        let instructions = try XCTUnwrap(planBody["instructions"] as? String)
        XCTAssertTrue(instructions.contains("PLAN MODE"))

        let buildBody = try bodyJSON(
            from: OpenAIResponsesRequest.make(
                baseURL: URL(string: "https://example.test/v1")!,
                apiKey: "test-key",
                providerRequest: makeProviderRequest(mode: .build)
            )
        )
        XCTAssertNil(
            buildBody["instructions"],
            "Build at Normal speed must leave the field out of the request"
        )
    }

    func testOpenCodePromptCarriesThePlanInstruction() throws {
        let message = ChatMessage(role: .user, text: "Add a settings toggle")

        let planParts = OpenCodePromptBuilder.parts(
            for: message,
            speedMode: .normal,
            mode: .plan
        )
        guard case let .text(planPrompt) = try XCTUnwrap(planParts.first) else {
            return XCTFail("The instruction travels in the first text part")
        }
        XCTAssertTrue(planPrompt.hasPrefix("PLAN MODE"))
        XCTAssertTrue(planPrompt.hasSuffix("Add a settings toggle"))

        let buildParts = OpenCodePromptBuilder.parts(
            for: message,
            speedMode: .normal,
            mode: .build
        )
        guard case let .text(buildPrompt) = try XCTUnwrap(buildParts.first) else {
            return XCTFail("Expected a text part")
        }
        XCTAssertEqual(
            buildPrompt,
            "Add a settings toggle",
            "Build mode must not decorate the prompt"
        )
    }

    func testAgentModePersistsWithTheOtherTurnPreferences() {
        let suiteName = "AgenticSidebarTests.AgentMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.agentMode, .build, "Build stays the default")

        store.agentMode = .plan

        XCTAssertEqual(
            SettingsStore(defaults: defaults).agentMode,
            .plan
        )
    }

    private func makeProviderRequest(mode: AgentMode) -> ProviderRequest {
        ProviderRequest(
            sessionID: UUID(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "Plan the change")],
            speedMode: .normal,
            mode: mode
        )
    }

    private func bodyJSON(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }
}

final class PlanDocumentParsingTests: XCTestCase {
    func testPlanFenceBecomesADocumentBlock() {
        let blocks = parseMarkdownBlocks(
            from: "Here is the plan.\n\n```plan\n# Goal\n- step one\n```\n\nDone."
        )

        XCTAssertEqual(blocks.count, 3)
        guard case let .plan(_, content) = blocks[1] else {
            return XCTFail("Expected a plan document, got \(blocks[1])")
        }
        XCTAssertTrue(content.contains("# Goal"))
        XCTAssertTrue(content.contains("- step one"))
    }

    func testPlanFenceLanguageIsMatchedCaseInsensitivelyWithATrailingHint() {
        let blocks = parseMarkdownBlocks(from: "```PLAN condensed\n- step\n```")
        guard case .plan = blocks.first else {
            return XCTFail("Expected a plan document, got \(String(describing: blocks.first))")
        }
    }

    func testPlanDocumentsAreNotRecognisedInsideAPlanDocument() {
        let blocks = parseMarkdownBlocks(
            from: "```plan\n- step\n```",
            allowsPlanDocuments: false
        )

        guard case let .code(_, language, _) = blocks.first else {
            return XCTFail("A nested fence must stay a code block")
        }
        XCTAssertEqual(language, "plan")
    }

    func testContainsPlanDocumentOnlyMatchesPlanFences() {
        XCTAssertTrue(containsPlanDocument("Sure:\n```plan\n- step\n```"))
        XCTAssertTrue(containsPlanDocument("```plan"))
        XCTAssertFalse(containsPlanDocument("Sure:\n```swift\nlet x = 1\n```"))
        XCTAssertFalse(containsPlanDocument("Nothing to approve here"))
    }
}

@MainActor
final class PromptQueueTests: XCTestCase {
    func testPromptArrivingDuringATurnIsQueuedAndDrainedInOrder() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("first"), .started)
        XCTAssertEqual(service.send("second"), .queued)
        XCTAssertEqual(service.send("third"), .queued)
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["second", "third"])

        gate.completeNext()
        let secondStarted = await waitUntil {
            service.state.messages.contains { $0.text == "second" }
        }
        XCTAssertTrue(
            secondStarted,
            "The next queued prompt starts as soon as the turn settles"
        )
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["third"])

        gate.completeNext()
        let thirdStarted = await waitUntil {
            service.state.messages.contains { $0.text == "third" }
        }
        XCTAssertTrue(thirdStarted)

        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)

        let userMessages = service.state.messages
            .filter { $0.role == .user }
            .map(\.text)
        XCTAssertEqual(userMessages, ["first", "second", "third"])
        XCTAssertTrue(service.queuedPrompts.isEmpty)
    }

    func testQueuedPromptKeepsTheModeAndSpeedItWasSentWith() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("first"), .started)
        XCTAssertEqual(
            service.send("plan this", speedMode: .fast, mode: .plan),
            .queued
        )

        let queued = service.queuedPrompts.first
        XCTAssertEqual(queued?.text, "plan this")
        XCTAssertEqual(queued?.speedMode, .fast)
        XCTAssertEqual(queued?.mode, .plan)

        gate.completeNext()
        let started = await waitUntil {
            service.state.messages.contains { $0.text == "plan this" }
        }
        XCTAssertTrue(started)
        gate.completeNext()
    }

    func testCancellingATurnStillSendsWhatWasQueued() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("long turn"), .started)
        XCTAssertEqual(service.send("follow up"), .queued)

        await service.cancel()

        let followUpStarted = await waitUntil {
            service.state.messages.contains { $0.text == "follow up" }
        }
        XCTAssertTrue(
            followUpStarted,
            "A cancelled turn must not strand the queue"
        )
        XCTAssertEqual(service.state.status, .streaming)

        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testQueuedPromptsCanBeRemovedAndCleared() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("first"), .started)
        XCTAssertEqual(service.send("second"), .queued)
        XCTAssertEqual(service.send("third"), .queued)

        if let secondID = service.queuedPrompts.first?.id {
            service.removeQueuedPrompt(secondID)
        }
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["third"])

        service.clearQueuedPrompts()
        XCTAssertTrue(service.queuedPrompts.isEmpty)

        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
        XCTAssertTrue(service.state.messages.allSatisfy { $0.text != "third" })
    }

    func testAQueuedMessageCanBeRewrittenWithoutLosingItsPlace() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("running turn"), .started)
        XCTAssertEqual(service.send("first queued", speedMode: .fast, mode: .plan), .queued)
        XCTAssertEqual(service.send("second queued"), .queued)

        let firstID = try? XCTUnwrap(service.queuedPrompts.first?.id)
        let edited = firstID.map { service.updateQueuedPrompt($0, text: "  corrected  ") }
        XCTAssertEqual(edited, true)

        XCTAssertEqual(
            service.queuedPrompts.map(\.text),
            ["corrected", "second queued"],
            "An edit must not move the message to the back of the queue"
        )
        XCTAssertEqual(
            service.queuedPrompts.first?.speedMode,
            .fast,
            "A correction keeps the speed and mode the turn was written with"
        )
        XCTAssertEqual(service.queuedPrompts.first?.mode, .plan)

        service.clearQueuedPrompts()
        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testAnEmptyEditIsRefusedRatherThanQueuedAsABlankPrompt() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("running turn"), .started)
        XCTAssertEqual(service.send("keep me"), .queued)

        let id = try? XCTUnwrap(service.queuedPrompts.first?.id)
        let refused = id.map { service.updateQueuedPrompt($0, text: "   ") }

        XCTAssertEqual(refused, false)
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["keep me"])
        XCTAssertEqual(
            service.updateQueuedPrompt(UUID(), text: "gone already"),
            false,
            "A prompt that is no longer queued cannot be edited"
        )

        service.clearQueuedPrompts()
        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testQueuedMessagesCanBeReordered() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("first"), .started)
        for text in ["a", "b", "c"] {
            XCTAssertEqual(service.send(text), .queued)
        }

        let lastID = try? XCTUnwrap(service.queuedPrompts.last?.id)
        let moved = lastID.map { service.moveQueuedPrompt($0, to: 0) }
        XCTAssertEqual(moved, true)
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["c", "a", "b"])

        let firstID = try? XCTUnwrap(service.queuedPrompts.first?.id)
        let movedToEnd = firstID.map { service.moveQueuedPrompt($0, to: 99) }
        XCTAssertEqual(movedToEnd, true, "Dropping past the end means the end, not nowhere")
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["a", "b", "c"])

        let stayID = try? XCTUnwrap(service.queuedPrompts.first?.id)
        let unchanged = stayID.map { service.moveQueuedPrompt($0, to: 0) }
        XCTAssertEqual(unchanged, false, "Dropping a message on itself changes nothing")
        XCTAssertEqual(service.queuedPrompts.map(\.text), ["a", "b", "c"])

        service.clearQueuedPrompts()
        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testAReorderedQueueRunsInTheNewOrder() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("first"), .started)
        XCTAssertEqual(service.send("second"), .queued)
        XCTAssertEqual(service.send("third"), .queued)

        if let thirdID = service.queuedPrompts.last?.id {
            service.moveQueuedPrompt(thirdID, to: 0)
        }

        gate.completeNext()
        var started = await waitUntil {
            service.state.messages.contains { $0.text == "third" }
        }
        XCTAssertTrue(started)

        gate.completeNext()
        started = await waitUntil {
            service.state.messages.contains { $0.text == "second" }
        }
        XCTAssertTrue(started)

        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)

        XCTAssertEqual(
            service.state.messages.filter { $0.role == .user }.map(\.text),
            ["first", "third", "second"],
            "The strip's order is the order the turns run in"
        )
    }

    func testEmptyOrUnconfiguredPromptsAreRejected() async {
        let service = AgentSessionService(runtimes: [])

        XCTAssertEqual(service.send("   "), .rejected)
        XCTAssertEqual(service.send("hello"), .rejected)
        XCTAssertTrue(service.queuedPrompts.isEmpty)
    }

    func testTheQueueRefusesMessagesOnceItIsFull() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("running turn"), .started)

        for index in 0..<AgentSession.maximumQueuedPrompts {
            XCTAssertEqual(service.send("queued \(index)"), .queued)
        }

        XCTAssertEqual(
            service.send("one too many"),
            .rejected,
            "An unanswered turn must not let the queue grow without bound"
        )
        XCTAssertEqual(service.queuedPrompts.count, AgentSession.maximumQueuedPrompts)
        XCTAssertFalse(service.queuedPrompts.contains { $0.text == "one too many" })

        service.clearQueuedPrompts()
        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testAFullQueueReportsThatItCannotAcceptAnotherMessage() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertTrue(service.canAcceptPrompt)
        XCTAssertEqual(service.send("running turn"), .started)
        XCTAssertTrue(
            service.canAcceptPrompt,
            "A running turn still takes a follow-up into its queue"
        )

        for index in 0..<AgentSession.maximumQueuedPrompts {
            XCTAssertEqual(service.send("queued \(index)"), .queued)
        }

        XCTAssertFalse(
            service.canAcceptPrompt,
            "Callers have to be able to see a full queue instead of discovering it by being refused"
        )

        service.clearQueuedPrompts()
        XCTAssertTrue(service.canAcceptPrompt)

        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testASessionWithNoProviderNeverAcceptsAPrompt() async {
        let service = AgentSessionService(runtimes: [])
        await service.refreshCapabilities()

        XCTAssertFalse(service.canAcceptPrompt)
        XCTAssertEqual(service.send("anything"), .rejected)
    }

    func testAnIdleSessionStartsImmediatelyInsteadOfQueueing() async {
        let gate = GatedProviderRuntime()
        let service = AgentSessionService(runtimes: [gate.runtime])
        await service.refreshCapabilities()

        XCTAssertEqual(service.send("only"), .started)
        XCTAssertTrue(service.queuedPrompts.isEmpty)
        XCTAssertTrue(service.isBusy)

        gate.completeNext()
        let settled = await waitUntil { !service.isBusy }
        XCTAssertTrue(settled)
    }

    func testSendingWithExistingQueueOnIdleSessionPreservesFIFOOrder() async {
        let gate = GatedProviderRuntime()
        let snapshot = SessionSnapshot(
            id: UUID(),
            createdAt: Date(),
            configuration: SessionConfiguration(
                providerID: gate.runtime.id,
                modelID: ProviderModelID("test-model"),
                variantID: nil
            ),
            messages: [],
            activityGroups: [],
            queuedPrompts: [
                QueuedPrompt(text: "existing queue 1"),
                QueuedPrompt(text: "existing queue 2")
            ]
        )
        let session = AgentSession(runtimes: [gate.runtime], snapshot: snapshot)

        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["existing queue 1", "existing queue 2"])

        let acceptance = session.send("new incoming")
        XCTAssertEqual(acceptance, .started)

        let startedFirst = await waitUntil {
            session.state.messages.contains { $0.text == "existing queue 1" }
        }
        XCTAssertTrue(startedFirst)
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["existing queue 2", "new incoming"])

        gate.completeNext()
        let startedSecond = await waitUntil {
            session.state.messages.contains { $0.text == "existing queue 2" }
        }
        XCTAssertTrue(startedSecond)
        XCTAssertEqual(session.queuedPrompts.map(\.text), ["new incoming"])

        gate.completeNext()
        let startedThird = await waitUntil {
            session.state.messages.contains { $0.text == "new incoming" }
        }
        XCTAssertTrue(startedThird)
        XCTAssertTrue(session.queuedPrompts.isEmpty)

        gate.completeNext()
        let settled = await waitUntil { !session.isBusy }
        XCTAssertTrue(settled)
    }
}

/// Holds one continuation per turn. Synchronous on purpose: the stream factory
/// runs in an async context, and a lock may not be taken directly from one.
///
/// A completion that arrives before any turn has opened is remembered and
/// applied to the next turn that does — otherwise the test would race the
/// session's turn task instead of asserting turn boundaries.
private final class TurnContinuations: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<ProviderEvent, Error>.Continuation] = []
    private var completionsWaitingForATurn = 0

    func open(
        _ continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) {
        lock.lock()
        if completionsWaitingForATurn > 0 {
            completionsWaitingForATurn -= 1
            lock.unlock()
            complete(continuation)
            return
        }
        continuations.append(continuation)
        lock.unlock()
    }

    /// Completes the oldest still-open turn, or the next one to open.
    func completeOldest() {
        lock.lock()
        guard !continuations.isEmpty else {
            completionsWaitingForATurn += 1
            lock.unlock()
            return
        }
        let next = continuations.removeFirst()
        lock.unlock()

        complete(next)
    }

    private func complete(
        _ continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) {
        continuation.yield(.completed)
        continuation.finish()
    }
}

/// A provider whose turn stream stays open until the test finishes it, so turn
/// boundaries can be asserted instead of raced.
private final class GatedProviderRuntime: @unchecked Sendable {
    let runtime: TestProviderRuntime

    private let turns: TurnContinuations

    init() {
        let turns = TurnContinuations()
        self.turns = turns

        runtime = TestProviderRuntime(
            id: ProviderID("gated"),
            displayName: "Gated",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("gated-1"),
                    displayName: "Gated One",
                    variants: []
                )
            ],
            streamFactory: { _ in
                let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
                turns.open(pair.continuation)
                return ProviderStream(events: pair.stream)
            }
        )
    }

    /// Completes the oldest still-open turn, or the next turn to start.
    func completeNext() {
        turns.completeOldest()
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }

    return condition()
}

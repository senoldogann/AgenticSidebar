import Foundation
import Synchronization
import XCTest

@testable import AgenticSidebar

final class OpenAITextCodingAdapterTests: XCTestCase {
    private struct MockProviderRuntime: ProviderRuntime {
        let id: ProviderID = ProviderID("openai")
        let models: [ProviderModelCapability]
        let streamEvents: [ProviderEvent]
        let onStreamStart: (@Sendable (ProviderRequest) -> Void)?

        init(
            models: [ProviderModelCapability] = [
                ProviderModelCapability(id: ProviderModelID("gpt-4o"), displayName: "GPT-4o", variants: [])
            ],
            streamEvents: [ProviderEvent] = [],
            onStreamStart: (@Sendable (ProviderRequest) -> Void)? = nil
        ) {
            self.models = models
            self.streamEvents = streamEvents
            self.onStreamStart = onStreamStart
        }

        func capabilities() async throws -> ProviderCapabilities {
            ProviderCapabilities(id: id, displayName: "OpenAI", models: models)
        }

        func startStream(for request: ProviderRequest) async throws -> ProviderStream {
            onStreamStart?(request)
            let channel = BoundedChannel<ProviderEvent>(capacity: 64)
            let events = streamEvents
            let task = Task {
                for event in events {
                    try Task.checkCancellation()
                    try await channel.send(event)
                }
                await channel.finish()
            }

            return ProviderStream(
                events: channel.makeStream(),
                cancellation: {
                    task.cancel()
                    await channel.finish(throwing: CancellationError())
                }
            )
        }
    }

    func testTruthfulCapabilitiesReporting() async {
        let runtime = MockProviderRuntime()
        let adapter = OpenAITextCodingAdapter(providerRuntime: runtime)

        let config = SessionConfiguration(
            providerID: ProviderID("openai"),
            modelID: ProviderModelID("gpt-4o")
        )

        let caps: CodingAgentCapabilities = await adapter.capabilities(configuration: config)

        // Truthful flags
        XCTAssertTrue(caps.contains(.textAnalysis))
        XCTAssertTrue(caps.contains(.cancellable))
        XCTAssertTrue(caps.contains(.structuredEvents))
        XCTAssertTrue(caps.contains(.usageReporting))

        // Explicitly NOT supported
        XCTAssertFalse(caps.contains(.workspaceRead), "Direct OpenAI runtime cannot read workspace directly")
        XCTAssertFalse(caps.contains(.workspaceWrite), "Direct OpenAI runtime cannot write workspace")
        XCTAssertFalse(caps.contains(.tools), "Direct OpenAI text runtime has no local tool execution")
        XCTAssertFalse(caps.contains(.interactiveApproval), "Direct OpenAI text runtime has no tool approval gates")
        XCTAssertFalse(caps.contains(.sessionResume), "Direct OpenAI text runtime is stateless completion")

        // Foreign provider config must return empty capabilities
        let foreignConfig = SessionConfiguration(
            providerID: ProviderID("opencode"),
            modelID: ProviderModelID("anthropic/claude-3-7-sonnet")
        )
        let foreignCaps: CodingAgentCapabilities = await adapter.capabilities(configuration: foreignConfig)
        XCTAssertEqual(foreignCaps, CodingAgentCapabilities([]))
    }

    func testRejectsImplementationAndWriteStages() async {
        let runtime = MockProviderRuntime()
        let adapter = OpenAITextCodingAdapter(providerRuntime: runtime)

        let config = SessionConfiguration(
            providerID: ProviderID("openai"),
            modelID: ProviderModelID("gpt-4o")
        )

        let stagesToReject: [TaskStage] = [.implementation, .verification, .codeReview, .qa, .acceptance]

        for stage in stagesToReject {
            let request = CodingAgentExecutionRequest(
                taskID: UUID(),
                attemptID: UUID(),
                generation: 1,
                role: .developer,
                configuration: config,
                objective: "Write code to implement feature",
                acceptanceCriteria: [],
                workspacePath: "/tmp/workspace",
                stage: stage
            )

            do {
                _ = try await adapter.start(request: request)
                XCTFail("Should have thrown CodingAgentAdapterError for unsupported stage \(stage)")
            } catch let error as CodingAgentAdapterError {
                if case .unsupportedStage(let rejectedStage) = error {
                    XCTAssertEqual(rejectedStage, stage)
                } else if case .unsupportedCapability = error {
                    // Also acceptable as unsupported capability
                } else {
                    XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testNoPromptLeakageIntoPersistedEventLog() async throws {
        let secretInstruction = "CONFIDENTIAL_ARCHITECTURAL_DECISION_ABC123"
        let objective = "Analyze microservice decoupling"

        let events: [ProviderEvent] = [
            .assistantTextDelta("Here is the architectural plan: "),
            .assistantTextDelta("Service A will communicate via gRPC with Service B."),
            .turnUsage(TurnTokenUsage(inputTokens: 120, outputTokens: 45)),
            .completed,
        ]

        let capturedRequest = Mutex<ProviderRequest?>(nil)
        let runtime = MockProviderRuntime(streamEvents: events) { req in
            capturedRequest.withLock { $0 = req }
        }

        let adapter = OpenAITextCodingAdapter(providerRuntime: runtime)
        let config = SessionConfiguration(
            providerID: ProviderID("openai"),
            modelID: ProviderModelID("gpt-4o")
        )

        let request = CodingAgentExecutionRequest(
            taskID: UUID(),
            attemptID: UUID(),
            generation: 1,
            role: .architect,
            configuration: config,
            objective: "\(objective) with key: \(secretInstruction)",
            acceptanceCriteria: [CodingAcceptanceCriterion(taskID: UUID(), description: "Low coupling")],
            workspacePath: "/tmp/fake",
            stage: .plan
        )

        let run = try await adapter.start(request: request)

        var collectedEvents: [CodingAgentEvent] = []
        for await event in run.events {
            collectedEvents.append(event)
        }

        XCTAssertNotNil(capturedRequest.withLock { $0 }, "Underlying request was dispatched")

        // Ensure the run emitted started, deltas, usage, and terminalSuccess
        XCTAssertTrue(collectedEvents.contains(where: { $0.kind == .started }))
        XCTAssertTrue(collectedEvents.contains(where: { $0.kind == .terminalSuccess }))

        // Gate: No event kind should echo or leak the input objective or secrets as event content
        for event in collectedEvents {
            switch event.kind {
            case .textDelta(let text):
                XCTAssertFalse(text.contains(secretInstruction), "Assistant output should not echo secret prompt")
            case .terminalError(let err):
                XCTAssertFalse(err.contains(secretInstruction))
            case .interrupted(let msg):
                XCTAssertFalse(msg.contains(secretInstruction))
            default:
                break
            }
        }
    }

    func testTextOnlyPlanningStreamsDeltasAndTerminatesSuccessfully() async throws {
        let events: [ProviderEvent] = [
            .assistantTextDelta("Step 1: Inspect schemas.\n"),
            .assistantTextDelta("Step 2: Define REST routes.\n"),
            .turnUsage(TurnTokenUsage(inputTokens: 80, outputTokens: 25)),
            .completed,
        ]

        let runtime = MockProviderRuntime(streamEvents: events)
        let adapter = OpenAITextCodingAdapter(providerRuntime: runtime)

        let config = SessionConfiguration(
            providerID: ProviderID("openai"),
            modelID: ProviderModelID("gpt-4o")
        )

        let request = CodingAgentExecutionRequest(
            taskID: UUID(),
            attemptID: UUID(),
            generation: 1,
            role: .architect,
            configuration: config,
            objective: "Design API contracts",
            acceptanceCriteria: [
                CodingAcceptanceCriterion(taskID: UUID(), description: "Contract adheres to OpenAPI 3.0")
            ],
            workspacePath: "/tmp/fake",
            stage: .plan
        )

        let run = try await adapter.start(request: request)

        var collected: [CodingAgentEvent] = []
        for await event in run.events {
            collected.append(event)
        }

        XCTAssertEqual(collected.first?.kind, .started)
        XCTAssertEqual(collected.last?.kind, .terminalSuccess)
        XCTAssertTrue(CodingAgentRun.isTerminatedSuccessfully(events: collected))

        let deltas = collected.compactMap { event -> String? in
            if case .textDelta(let text) = event.kind { return text }
            return nil
        }
        XCTAssertEqual(deltas.joined(), "Step 1: Inspect schemas.\nStep 2: Define REST routes.\n")

        let usageEvents = collected.compactMap { event -> (Int, Int)? in
            if case .usage(let inp, let out) = event.kind { return (inp, out) }
            return nil
        }
        XCTAssertEqual(usageEvents.count, 1)
        XCTAssertEqual(usageEvents.first?.0, 80)
        XCTAssertEqual(usageEvents.first?.1, 25)
    }

    func testCancellationTerminatesPromptly() async throws {
        let channel = BoundedChannel<ProviderEvent>(capacity: 64)
        struct InfiniteRuntime: ProviderRuntime {
            let id: ProviderID = ProviderID("openai")
            let channel: BoundedChannel<ProviderEvent>

            func capabilities() async throws -> ProviderCapabilities {
                ProviderCapabilities(id: id, displayName: "OpenAI", models: [])
            }

            func startStream(for request: ProviderRequest) async throws -> ProviderStream {
                ProviderStream(
                    events: channel.makeStream(),
                    cancellation: {
                        await channel.finish(throwing: CancellationError())
                    }
                )
            }
        }

        let runtime = InfiniteRuntime(channel: channel)
        let adapter = OpenAITextCodingAdapter(providerRuntime: runtime)

        let config = SessionConfiguration(
            providerID: ProviderID("openai"),
            modelID: ProviderModelID("gpt-4o")
        )

        let request = CodingAgentExecutionRequest(
            taskID: UUID(),
            attemptID: UUID(),
            generation: 1,
            role: .architect,
            configuration: config,
            objective: "Long planning session",
            acceptanceCriteria: [],
            workspacePath: "/tmp/fake",
            stage: .plan
        )

        let run = try await adapter.start(request: request)

        var iterator = run.events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.kind, .started)

        // Cancel the run while waiting for provider events
        await run.cancel()

        var remaining: [CodingAgentEvent] = []
        while let next = await iterator.next() {
            remaining.append(next)
        }

        XCTAssertTrue(
            remaining.contains(where: {
                if case .interrupted = $0.kind { return true }
                return false
            }))
        XCTAssertFalse(CodingAgentRun.isTerminatedSuccessfully(events: [first!].compactMap { $0 } + remaining))
    }
}

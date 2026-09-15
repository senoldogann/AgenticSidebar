import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class FirstMilestoneIntegrationTests: XCTestCase {
    func testTwoBackendsCoexistAndSubmissionRoutesToSelectedRuntime() async throws {
        let openAIRecorder = AcceptanceRequestRecorder()
        let openCodeRecorder = AcceptanceRequestRecorder()

        let openAI = TestProviderRuntime(
            id: ProviderID("openai"),
            displayName: "OpenAI",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("gpt-5.6"),
                    displayName: "GPT-5.6",
                    variants: [
                        ProviderVariant(
                            id: ProviderVariantID("high"),
                            displayName: "High"
                        )
                    ]
                )
            ],
            streamFactory: { request in
                await openAIRecorder.record(request)
                return completedAcceptanceStream(text: "OpenAI reply")
            }
        )
        let openCode = TestProviderRuntime(
            id: ProviderID("opencode"),
            displayName: "OpenCode",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("openai/gpt-5.6"),
                    displayName: "OpenAI · GPT-5.6",
                    variants: [
                        ProviderVariant(
                            id: ProviderVariantID("xhigh"),
                            displayName: "XHigh"
                        )
                    ]
                )
            ],
            streamFactory: { request in
                await openCodeRecorder.record(request)
                return completedAcceptanceStream(text: "OpenCode reply")
            }
        )
        let service = AgentSessionService(runtimes: [openAI, openCode])

        await service.refreshCapabilities()

        XCTAssertEqual(service.providers.map(\.id), [ProviderID("openai"), ProviderID("opencode")])
        try service.selectProvider(ProviderID("opencode"))
        try service.selectModel(ProviderModelID("openai/gpt-5.6"))
        try service.selectVariant(ProviderVariantID("xhigh"))

        let task = try XCTUnwrap(service.submit("Run through OpenCode"))
        await task.value

        let openAIRequests = await openAIRecorder.requests()
        XCTAssertEqual(openAIRequests.count, 0)
        let openCodeRequests = await openCodeRecorder.requests()
        XCTAssertEqual(openCodeRequests.count, 1)
        XCTAssertEqual(openCodeRequests.first?.configuration.providerID, ProviderID("opencode"))
        XCTAssertEqual(openCodeRequests.first?.configuration.modelID, ProviderModelID("openai/gpt-5.6"))
        XCTAssertEqual(openCodeRequests.first?.configuration.variantID, ProviderVariantID("xhigh"))
        XCTAssertEqual(service.state.status, .completed)
        XCTAssertEqual(service.state.messages.last?.role, .assistant)
        XCTAssertEqual(service.state.messages.last?.text, "OpenCode reply")
    }

    func testOwnedSessionContinuesWithoutPresentationInteraction() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let runtime = TestProviderRuntime(
            id: ProviderID("openai"),
            displayName: "OpenAI",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("gpt-5.6"),
                    displayName: "GPT-5.6",
                    variants: []
                )
            ],
            streamFactory: { _ in
                ProviderStream(
                    events: pair.stream,
                    cancellation: {
                        pair.continuation.finish(throwing: CancellationError())
                    }
                )
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Continue while presentation is absent"))
        XCTAssertEqual(service.state.status, .streaming)

        pair.continuation.yield(.assistantTextDelta("Still running"))
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await task.value

        XCTAssertEqual(service.state.status, .completed)
        XCTAssertEqual(service.state.messages.last?.role, .assistant)
        XCTAssertEqual(service.state.messages.last?.text, "Still running")
    }
}

private func completedAcceptanceStream(text: String) -> ProviderStream {
    let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
    pair.continuation.yield(.assistantTextDelta(text))
    pair.continuation.yield(.completed)
    pair.continuation.finish()
    return ProviderStream(events: pair.stream)
}

private actor AcceptanceRequestRecorder {
    private var recorded: [ProviderRequest] = []

    func record(_ request: ProviderRequest) {
        recorded.append(request)
    }

    func requests() -> [ProviderRequest] {
        recorded
    }
}

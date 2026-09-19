import Foundation
import XCTest

@testable import AgenticSidebar

final class CodingAgentRegistryTests: XCTestCase {
    struct MockRuntime: CodingAgentRuntime {
        let runtimeID: String
        let capabilities: CodingAgentCapabilities

        func capabilities(configuration: SessionConfiguration) async -> CodingAgentCapabilities {
            capabilities
        }

        func start(request: CodingAgentExecutionRequest) async throws -> CodingAgentRun {
            let (stream, continuation) = AsyncStream.makeStream(of: CodingAgentEvent.self)
            continuation.yield(
                CodingAgentEvent(
                    taskID: request.taskID,
                    attemptID: request.attemptID,
                    generation: request.generation,
                    timestamp: Date(),
                    kind: .started
                ))
            continuation.yield(
                CodingAgentEvent(
                    taskID: request.taskID,
                    attemptID: request.attemptID,
                    generation: request.generation,
                    timestamp: Date(),
                    kind: .terminalSuccess
                ))
            continuation.finish()
            return CodingAgentRun(events: stream, cancel: {})
        }

        func release(attemptID: UUID) async {}
    }

    private func makeConfig() -> SessionConfiguration {
        SessionConfiguration(
            providerID: ProviderID("test-provider"),
            modelID: ProviderModelID("test-model")
        )
    }

    func testOpenAITextOnlyFailsWorkspaceWriteAndToolsEligibility() async {
        let registry = CodingAgentRegistry()
        let textOnlyRuntime = MockRuntime(
            runtimeID: "openai-text-only",
            capabilities: [.textAnalysis, .structuredEvents, .usageReporting]
        )
        registry.register(runtime: textOnlyRuntime)

        let required: CodingAgentCapabilities = [.workspaceRead, .workspaceWrite, .tools]
        let result = await registry.checkEligibility(
            runtimeID: "openai-text-only",
            configuration: makeConfig(),
            required: required
        )

        switch result {
        case .supported:
            XCTFail("Text-only runtime must NOT be eligible for workspace writing or tool execution")
        case .missingCapabilities(let missing, let available):
            XCTAssertTrue(missing.contains("workspaceWrite"), "Must report missing workspaceWrite")
            XCTAssertTrue(missing.contains("workspaceRead"), "Must report missing workspaceRead")
            XCTAssertTrue(missing.contains("tools"), "Must report missing tools")
            XCTAssertFalse(available.contains(.workspaceWrite))
        case .runtimeNotFound:
            XCTFail("Runtime should be found")
        }
    }

    func testNonExistentProviderDoesNotSilentlyFallback() async {
        let registry = CodingAgentRegistry()
        let textOnlyRuntime = MockRuntime(
            runtimeID: "mock-runtime-1",
            capabilities: [.textAnalysis]
        )
        registry.register(runtime: textOnlyRuntime)

        let result = await registry.checkEligibility(
            runtimeID: "non-existent-provider",
            configuration: makeConfig(),
            required: [.textAnalysis]
        )

        switch result {
        case .runtimeNotFound(let id):
            XCTAssertEqual(id, "non-existent-provider")
        case .supported, .missingCapabilities:
            XCTFail("Non-existent provider must never be supported or report missing capabilities")
        }
    }

    func testMissingCancellationIsNotAdvertisedAsPresent() async {
        let registry = CodingAgentRegistry()
        let nonCancellableRuntime = MockRuntime(
            runtimeID: "non-cancellable",
            capabilities: [.textAnalysis, .workspaceRead, .workspaceWrite, .tools]
        )
        registry.register(runtime: nonCancellableRuntime)

        let required: CodingAgentCapabilities = [.workspaceWrite, .cancellable]
        let result = await registry.checkEligibility(
            runtimeID: "non-cancellable",
            configuration: makeConfig(),
            required: required
        )

        switch result {
        case .missingCapabilities(let missing, let available):
            XCTAssertTrue(missing.contains("cancellable"), "Must honestly report lack of cancellation capability")
            XCTAssertFalse(available.contains(.cancellable))
        default:
            XCTFail("Expected missing capabilities for cancellation")
        }
    }
}

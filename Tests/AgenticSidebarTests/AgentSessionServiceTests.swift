import XCTest
@testable import AgenticSidebar

@MainActor
final class AgentSessionServiceTests: XCTestCase {
    func testRefreshCapabilitiesSelectsFirstProviderAndModel() async {
        let service = AgentSessionService(
            runtimes: [
                makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast"),
                makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep")
            ]
        )

        await service.refreshCapabilities()

        XCTAssertEqual(service.providers.map(\.id), [ProviderID("alpha"), ProviderID("beta")])
        XCTAssertEqual(service.state.configuration?.providerID, ProviderID("alpha"))
        XCTAssertEqual(service.state.configuration?.modelID, ProviderModelID("alpha-1"))
        XCTAssertNil(service.state.configuration?.variantID)
    }

    func testSwitchingProviderRebuildsConfigurationFromThatProvidersCapabilities() async throws {
        let service = AgentSessionService(
            runtimes: [
                makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast"),
                makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep")
            ]
        )
        await service.refreshCapabilities()
        try service.selectVariant(ProviderVariantID("fast"))

        try service.selectProvider(ProviderID("beta"))

        XCTAssertEqual(service.state.configuration?.providerID, ProviderID("beta"))
        XCTAssertEqual(service.state.configuration?.modelID, ProviderModelID("beta-1"))
        XCTAssertNil(service.state.configuration?.variantID)
    }

    func testUnsupportedVariantDoesNotMutateValidConfiguration() async throws {
        let service = AgentSessionService(
            runtimes: [
                makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast")
            ]
        )
        await service.refreshCapabilities()
        let originalConfiguration = service.state.configuration

        XCTAssertThrowsError(
            try service.selectVariant(ProviderVariantID("unsupported"))
        ) { error in
            XCTAssertEqual(error as? AgentSessionError, .unsupportedCapability)
        }
        XCTAssertEqual(service.state.configuration, originalConfiguration)
    }

    func testEmptyRuntimeListIsAValidIdlePreAdapterState() async {
        let service = AgentSessionService(runtimes: [])

        await service.refreshCapabilities()

        XCTAssertTrue(service.providers.isEmpty)
        XCTAssertNil(service.state.configuration)
        XCTAssertEqual(service.state.status, .idle)
        XCTAssertNil(service.state.error)
        XCTAssertFalse(service.canSubmit)
    }

    func testStreamingDeltasBuildOneAssistantMessage() async throws {
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
            streamFactory: { _ in
                let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
                pair.continuation.yield(.assistantTextDelta("Hello"))
                pair.continuation.yield(.assistantTextDelta(" world"))
                pair.continuation.yield(.completed)
                pair.continuation.finish()
                return ProviderStream(events: pair.stream)
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))
        await task.value

        XCTAssertEqual(service.state.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(service.state.messages.map(\.text), ["Hi", "Hello world"])
        XCTAssertEqual(service.state.status, .completed)
        XCTAssertNil(service.state.error)
        XCTAssertNotNil(service.state.startedAt)
        XCTAssertNotNil(service.state.completedAt)
    }

    func testActivitiesAreAnchoredSanitizedAndCompletedWithTheirTurn() async throws {
        let activityID = ProviderActivityID("part-read")
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
            streamFactory: { _ in
                let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
                pair.continuation.yield(
                    .activityStarted(
                        ProviderActivityDescriptor(
                            id: activityID,
                            kind: .read
                        )
                    )
                )
                pair.continuation.yield(
                    .activityFinished(
                        activityID,
                        outcome: .completed
                    )
                )
                pair.continuation.yield(.assistantTextDelta("Done"))
                pair.continuation.yield(.completed)
                pair.continuation.finish()
                return ProviderStream(events: pair.stream)
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Read the project"))
        await task.value

        let userMessage = try XCTUnwrap(service.state.messages.first)
        let group = try XCTUnwrap(service.state.activityGroups.first)
        XCTAssertEqual(group.anchorMessageID, userMessage.id)
        XCTAssertEqual(group.activities.map(\.kind), [.thinking, .read])
        XCTAssertTrue(group.activities.allSatisfy { $0.phase == .completed })
    }

    func testCancellationCancelsProviderStreamAndRejectsStaleEvents() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let cancellationProbe = CancellationProbe()
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
            streamFactory: { _ in
                ProviderStream(
                    events: pair.stream,
                    cancellation: {
                        await cancellationProbe.record()
                        pair.continuation.finish(throwing: CancellationError())
                    }
                )
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()
        let task = try XCTUnwrap(service.submit("Hi"))

        pair.continuation.yield(.assistantTextDelta("Partial"))
        for _ in 0..<100 where service.state.messages.last?.text != "Partial" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.state.messages.last?.text, "Partial")

        await service.cancel()
        await task.value

        XCTAssertEqual(service.state.status, .cancelled)
        let cancellationCount = await cancellationProbe.count()
        XCTAssertEqual(cancellationCount, 1)

        pair.continuation.yield(.assistantTextDelta(" stale"))
        await Task.yield()
        XCTAssertEqual(service.state.messages.last?.text, "Partial")
    }

    func testStartStreamFailureIsNormalizedToTransportFailure() async throws {
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
            streamFactory: { _ in
                throw SensitiveProviderError(message: "authorization=do-not-surface")
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))
        await task.value

        XCTAssertEqual(service.state.status, .failed)
        XCTAssertEqual(service.state.error, .transportFailure)
    }

    func testStreamEndingBeforeCompletedIsNormalizedToInterruption() async throws {
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
            streamFactory: { _ in
                let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
                pair.continuation.yield(.assistantTextDelta("Partial"))
                pair.continuation.finish()
                return ProviderStream(events: pair.stream)
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))
        await task.value

        XCTAssertEqual(service.state.status, .failed)
        XCTAssertEqual(service.state.error, .streamInterrupted)
        XCTAssertEqual(service.state.messages.last?.text, "Partial")
    }

    func testMissingCredentialCapabilityFailureIsPreserved() async {
        let runtime = FailingCapabilitiesRuntime(error: ProviderRuntimeError.missingCredential)
        let service = AgentSessionService(runtimes: [runtime])

        await service.refreshCapabilities()

        XCTAssertEqual(service.state.status, .failed)
        XCTAssertEqual(service.state.error, .missingCredential)
    }

    func testProviderRuntimeErrorsMapToSessionErrors() async throws {
        let mappings: [(ProviderRuntimeError, AgentSessionError)] = [
            (.missingCredential, .missingCredential),
            (.executableUnavailable, .backendExecutableUnavailable),
            (.startupFailure, .backendStartupFailure),
            (.authenticationFailure, .authenticationFailure),
            (.unavailable, .providerUnavailable),
            (.transport, .transportFailure),
            (.unexpectedResponse, .unexpectedBackendResponse)
        ]

        for (runtimeError, expectedError) in mappings {
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
                streamFactory: { _ in
                    throw runtimeError
                }
            )
            let service = AgentSessionService(runtimes: [runtime])
            await service.refreshCapabilities()

            let task = try XCTUnwrap(service.submit("Hi"))
            await task.value

            XCTAssertEqual(service.state.status, .failed)
            XCTAssertEqual(service.state.error, expectedError)
        }
    }

    private func makeRuntime(
        id: String,
        modelID: String,
        variantID: String
    ) -> TestProviderRuntime {
        TestProviderRuntime(
            id: ProviderID(id),
            displayName: id.capitalized,
            models: [
                ProviderModelCapability(
                    id: ProviderModelID(modelID),
                    displayName: modelID,
                    variants: [
                        ProviderVariant(
                            id: ProviderVariantID(variantID),
                            displayName: variantID.capitalized
                        )
                    ]
                )
            ]
        )
    }
}

private struct FailingCapabilitiesRuntime: ProviderRuntime {
    let id = ProviderID("failing")
    let error: ProviderRuntimeError

    func capabilities() async throws -> ProviderCapabilities {
        throw error
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        throw error
    }
}

private struct SensitiveProviderError: Error, Sendable {
    let message: String
}

private actor CancellationProbe {
    private var cancellationCount = 0

    func record() {
        cancellationCount += 1
    }

    func count() -> Int {
        cancellationCount
    }
}

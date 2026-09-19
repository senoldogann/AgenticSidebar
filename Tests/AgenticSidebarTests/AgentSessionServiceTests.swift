import XCTest

@testable import AgenticSidebar

@MainActor
final class AgentSessionServiceTests: XCTestCase {
    func testRefreshCapabilitiesSelectsFirstProviderAndModel() async {
        let service = AgentSessionService(
            runtimes: [
                makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast"),
                makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep"),
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
                makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep"),
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
        // Düşünme tembeldir: thinking deltası gelmeyen turda boş `.thinking`
        // satırı kurulmaz.
        XCTAssertEqual(group.activities.map(\.kind), [.read])
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
            (.unexpectedResponse, .unexpectedBackendResponse),
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

    /// İki kez üst üste durdurma tek sonuç verir ve sonraki turu bozmaz.
    ///
    /// Durdurma düğmesine çift tıklamak (ya da iptal ile kuyruk boşaltımının
    /// yarışması) eskiden bitmiş turun tutamacıyla koşan turun durumunu
    /// ezebiliyordu: sonraki tur sahipsiz akışla baş başa kalıyor, durdurma
    /// simgesi ekranda takılı kalıyordu.
    func testDoubleCancelSettlesOnceAndLeavesTheNextTurnAlone() async throws {
        final class StreamPairs: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            let first = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            let second = AsyncThrowingStream<ProviderEvent, Error>.makeStream()

            func next() -> AsyncThrowingStream<ProviderEvent, Error> {
                lock.withLock {
                    calls += 1
                    return calls == 1 ? first.stream : second.stream
                }
            }

            func cancelFirst() {
                first.continuation.finish(throwing: CancellationError())
            }
        }
        let pairs = StreamPairs()
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
                // İlk turun akışı iptalde sonlanır, ikincisi testin elindedir.
                ProviderStream(
                    events: pairs.next(),
                    cancellation: { pairs.cancelFirst() }
                )
            }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))
        XCTAssertTrue(service.isBusy)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await service.cancel() }
            group.addTask { await service.cancel() }
        }
        await task.value

        XCTAssertEqual(service.state.status, .cancelled)
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(service.activeTurnID)

        // Sonraki tur tertemiz başlar ve biter: sahipsiz akış kalmamıştır.
        let followUp = try XCTUnwrap(service.submit("Again"))
        pairs.second.continuation.yield(.assistantTextDelta("Back"))
        pairs.second.continuation.yield(.completed)
        pairs.second.continuation.finish()
        await followUp.value

        XCTAssertEqual(service.state.status, .completed)
        XCTAssertFalse(service.isBusy)
        XCTAssertEqual(service.state.messages.last?.text, "Back")
    }

    func testCancelWithoutARunningTurnIsANoOp() async {
        let service = AgentSessionService(runtimes: [
            makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast")
        ])
        await service.refreshCapabilities()

        await service.cancel()

        XCTAssertEqual(service.state.status, .idle)
        XCTAssertNil(service.activeTurnID)
        XCTAssertFalse(service.isBusy)
    }

    /// Başka sağlayıcıya geçince önceki listenin kartı ekranda kalmamalı.
    ///
    /// Listesi olmayan sağlayıcı `nil` döner ve son listeyi yerinde bırakır;
    /// o yüzden yapılandırma değişiminde liste düşürülür — yoksa OpenAI
    /// turunda OpenCode'un bayat kontrol listesi görünürdü.
    func testSwitchingProviderDropsThePreviousChecklist() throws {
        let alpha = makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast")
        let beta = makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep")
        let session = AgentSession(runtimes: [alpha, beta])
        session.applyCapabilities(
            [alpha.capabilitySet, beta.capabilitySet],
            normalizeConfiguration: true
        )
        try session.selectProvider(ProviderID("alpha"))

        session.state.todos = [
            AgentTodo(id: "t1", content: "Write it", status: .inProgress)
        ]
        try session.selectProvider(ProviderID("beta"))

        XCTAssertTrue(
            session.state.todos.isEmpty,
            "Another provider's checklist must not survive the switch"
        )
    }

    func testStaleTodoReadDoesNotSurviveProviderSwitch() async throws {
        let alpha = DelayedTodosRuntime(
            id: ProviderID("alpha"),
            modelID: ProviderModelID("alpha-1"),
            todos: [AgentTodo(id: "t1", content: "Write it", status: .inProgress)],
            delayMilliseconds: 200
        )
        let beta = makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep")
        let session = AgentSession(runtimes: [alpha, beta])
        session.applyCapabilities(
            [alpha.capabilitySet, beta.capabilitySet],
            normalizeConfiguration: true
        )
        try session.selectProvider(ProviderID("alpha"))
        session.refreshTodos()
        try session.selectProvider(ProviderID("beta"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(
            session.state.todos.isEmpty,
            "A slow todo answer for the previous provider must not land after the switch"
        )
    }

    func testCapabilityRefreshFallingBackToAnotherProviderDropsTheChecklist() throws {
        let alpha = makeRuntime(id: "alpha", modelID: "alpha-1", variantID: "fast")
        let beta = makeRuntime(id: "beta", modelID: "beta-1", variantID: "deep")
        let session = AgentSession(runtimes: [alpha, beta])
        session.applyCapabilities(
            [alpha.capabilitySet, beta.capabilitySet],
            normalizeConfiguration: true
        )
        try session.selectProvider(ProviderID("alpha"))
        session.state.todos = [
            AgentTodo(id: "t1", content: "Write it", status: .inProgress)
        ]

        // Aynı sağlayıcı kümesi listeyi korumalı…
        session.applyCapabilities(
            [alpha.capabilitySet, beta.capabilitySet],
            normalizeConfiguration: true
        )
        XCTAssertEqual(session.state.todos.count, 1)

        // …ama alpha ortadan kalkıp yapılandırma beta'ya düşünce liste düşer.
        session.applyCapabilities([beta.capabilitySet], normalizeConfiguration: true)
        XCTAssertEqual(session.state.configuration?.providerID, ProviderID("beta"))
        XCTAssertTrue(session.state.todos.isEmpty)
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

private struct DelayedTodosRuntime: ProviderRuntime {
    let id: ProviderID
    let capabilitySet: ProviderCapabilities
    let todos: [AgentTodo]
    let delayMilliseconds: UInt64

    init(id: ProviderID, modelID: ProviderModelID, todos: [AgentTodo], delayMilliseconds: UInt64) {
        self.id = id
        self.capabilitySet = ProviderCapabilities(
            id: id,
            displayName: id.rawValue.capitalized,
            models: [ProviderModelCapability(id: modelID, displayName: modelID.rawValue, variants: [])]
        )
        self.todos = todos
        self.delayMilliseconds = delayMilliseconds
    }

    func capabilities() async throws -> ProviderCapabilities {
        capabilitySet
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        throw ProviderRuntimeError.unsupported
    }

    func sessionTodos(sessionID: UUID) async -> [AgentTodo]? {
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        return todos
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

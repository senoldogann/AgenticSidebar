import XCTest

@testable import AgenticSidebar

@MainActor
final class SessionFailureTaxonomyTests: XCTestCase {
    func testMissingCredentialIsPreferredOverAnUnavailableProvider() async {
        let service = AgentSessionService(
            runtimes: [
                FailingRuntime(id: ProviderID("openai"), error: .missingCredential),
                FailingRuntime(id: ProviderID("opencode"), error: .unavailable),
            ]
        )

        await service.refreshCapabilities()

        XCTAssertEqual(service.state.status, .failed)
        XCTAssertEqual(
            service.state.error,
            .missingCredential,
            "A missing credential must not be hidden behind an unrelated provider outage"
        )
    }

    func testRateLimitedProviderIsReportedAsRateLimited() async throws {
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
            streamFactory: { _ in throw ProviderRuntimeError.rateLimited }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))
        await task.value

        XCTAssertEqual(service.state.status, .failed)
        XCTAssertEqual(service.state.error, .rateLimited)
    }

    func testWaitingStatusIsNotOverwrittenWhenAnActivityFinishes() async throws {
        let activityID = ProviderActivityID("part-tool")
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
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
            streamFactory: { _ in ProviderStream(events: pair.stream) }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))

        pair.continuation.yield(
            .activityStarted(
                ProviderActivityDescriptor(id: activityID, kind: .read)
            )
        )
        pair.continuation.yield(.waiting)
        pair.continuation.yield(
            .activityFinished(activityID, outcome: .completed)
        )

        for _ in 0..<200 where !isActivityCompleted(service, activityID: activityID) {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            service.state.status,
            .waiting,
            "A finished activity must not replace a newer waiting status"
        )

        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await task.value

        XCTAssertEqual(service.state.status, .completed)
    }

    /// Sağlayıcı "bitti" dedi ama hiç metin/araç üretmediyse bu sessiz bir
    /// başarı değildir: kullanıcı ekranda yeni hiçbir şey göremez ve "ajan
    /// başlamadı" der. Ölçülen olay (OpenCode oturum günlüğü): kullanıcı mesajı
    /// oluşur, yalnız `agent=title` koşar, model turu hiç başlamaz ve gelen tek
    /// olay `session.idle` olur.
    func testATurnThatCompletesWithNoOutputIsReportedAsAFailure() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
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
            streamFactory: { _ in ProviderStream(events: pair.stream) }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))

        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await task.value

        XCTAssertEqual(service.state.status, .failed)
        XCTAssertEqual(service.state.error, .unexpectedBackendResponse)
        XCTAssertEqual(
            service.state.messages.map(\.role),
            [.user],
            "boş tur transkripte sahte bir yanıt yazmamalı"
        )
    }

    /// Araç çalıştırıp metin üretmeyen bir tur normaldir; başarısız sayılmaz.
    func testAToolOnlyTurnIsNotReportedAsAFailure() async throws {
        let activityID = ProviderActivityID("part-tool")
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
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
            streamFactory: { _ in ProviderStream(events: pair.stream) }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))

        pair.continuation.yield(
            .activityStarted(
                ProviderActivityDescriptor(id: activityID, kind: .read)
            )
        )
        pair.continuation.yield(
            .activityFinished(activityID, outcome: .completed)
        )
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await task.value

        XCTAssertEqual(service.state.status, .completed)
    }

    func testFinishedActivityKeepsItsDescriptorAndTiming() async throws {
        let activityID = ProviderActivityID("part-command")
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
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
            streamFactory: { _ in ProviderStream(events: pair.stream) }
        )
        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()

        let task = try XCTUnwrap(service.submit("Hi"))

        pair.continuation.yield(
            .activityStarted(
                ProviderActivityDescriptor(
                    id: activityID,
                    kind: .command,
                    title: "Running swift test",
                    detail: "swift test",
                    output: "All tests passed"
                )
            )
        )
        // The turn ends while the tool is still marked running: the finish step
        // has to close the activity out without losing what it already carried.
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await task.value

        let activity = try XCTUnwrap(
            service.state.activityGroups
                .flatMap(\.activities)
                .first { $0.id == activityID }
        )
        XCTAssertEqual(activity.phase, .completed)
        XCTAssertEqual(
            activity.title,
            "Running swift test",
            "Finishing a turn must not drop the tool title"
        )
        XCTAssertEqual(activity.output, "All tests passed", "Tool output must survive the finish step")
        let completedAt = try XCTUnwrap(activity.completedAt)
        XCTAssertLessThanOrEqual(activity.startedAt, completedAt)
    }

    func testEverySessionErrorHasUserFacingPresentation() {
        let errors: [AgentSessionError] = [
            .missingCredential,
            .backendExecutableUnavailable,
            .backendStartupFailure,
            .authenticationFailure,
            .providerUnavailable,
            .rateLimited,
            .unsupportedCapability,
            .transportFailure,
            .streamInterrupted,
            .unexpectedBackendResponse,
        ]

        for error in errors {
            XCTAssertFalse(error.message.isEmpty, "\(error) must explain itself")
            XCTAssertFalse(error.symbolName.isEmpty, "\(error) must provide a symbol")
        }
    }

    private func isActivityCompleted(
        _ service: AgentSessionService,
        activityID: ProviderActivityID
    ) -> Bool {
        service.state.activityGroups
            .flatMap(\.activities)
            .contains { $0.id == activityID && $0.phase == .completed }
    }
}

private struct FailingRuntime: ProviderRuntime {
    let id: ProviderID
    let error: ProviderRuntimeError

    func capabilities() async throws -> ProviderCapabilities {
        throw error
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        throw error
    }
}

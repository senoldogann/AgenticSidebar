import XCTest

@testable import AgenticSidebar

/// Bağlam halkasının girdisi: yalnız sağlayıcı bildirimi ve pencere.
/// Bildirim ya da pencere yoksa oran `nil`dir, tahmin uydurulmaz.
@MainActor
final class SessionContextUsageTests: XCTestCase {
    private struct UsageRuntime: ProviderRuntime {
        let id = ProviderID("opencode")
        let usage: TurnTokenUsage

        func capabilities() async throws -> ProviderCapabilities {
            ProviderCapabilities(id: id, displayName: "Test", models: [])
        }

        func startStream(for request: ProviderRequest) async throws -> ProviderStream {
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.turnUsage(usage))
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }
    }

    private func makeSession(usage: TurnTokenUsage) -> AgentSession {
        AgentSession(
            runtimes: [UsageRuntime(usage: usage)],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("opencode"),
                    modelID: ProviderModelID("m1"),
                    variantID: nil
                )
            )
        )
    }

    private func capabilities() -> ProviderCapabilities {
        ProviderCapabilities(
            id: ProviderID("opencode"),
            displayName: "Test",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("m1"),
                    displayName: "M1",
                    variants: [],
                    contextLimit: 100_000
                ),
                ProviderModelCapability(
                    id: ProviderModelID("m2"),
                    displayName: "M2",
                    variants: [],
                    contextLimit: 200_000
                ),
            ]
        )
    }

    private func waitForSettled(_ session: AgentSession) async {
        for _ in 0..<600 {
            if !session.isBusy {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testFractionIsNilWithoutReportOrLimit() {
        let neither = SessionContextUsage(
            usedTokens: nil,
            limitTokens: nil,
            lastInputTokens: nil,
            lastOutputTokens: nil
        )
        XCTAssertNil(neither.fraction)

        let noReport = SessionContextUsage(
            usedTokens: nil,
            limitTokens: 200_000,
            lastInputTokens: nil,
            lastOutputTokens: nil
        )
        XCTAssertNil(noReport.fraction)

        let noLimit = SessionContextUsage(
            usedTokens: 50_000,
            limitTokens: nil,
            lastInputTokens: 50_000,
            lastOutputTokens: 100
        )
        XCTAssertNil(noLimit.fraction)
    }

    func testFractionIsClampedToOne() {
        let usage = SessionContextUsage(
            usedTokens: 500_000,
            limitTokens: 200_000,
            lastInputTokens: 500_000,
            lastOutputTokens: 1_000
        )
        XCTAssertEqual(usage.fraction ?? -1, 1, accuracy: 0.0001)
    }

    /// Bildirim yoksa pay `nil`dir: tur metni birikse bile tahmin uydurulmaz.
    func testNoReportMeansNilUsageDespiteTranscript() async {
        let session = makeSession(
            usage: TurnTokenUsage(inputTokens: 50_000, outputTokens: 100)
        )

        let before = session.contextUsage
        XCTAssertNil(before.usedTokens)
        XCTAssertNil(before.fraction)
        XCTAssertNil(before.lastInputTokens)
    }

    /// Sağlayıcı bildirimi halkanın payıdır.
    func testReportedUsageIsShown() async {
        let session = makeSession(
            usage: TurnTokenUsage(inputTokens: 50_000, outputTokens: 100)
        )
        session.applyCapabilities([capabilities()], normalizeConfiguration: false)

        let turn = session.submit("Hi")
        await turn?.value
        await waitForSettled(session)

        XCTAssertEqual(session.lastTurnUsage?.inputTokens, 50_000)
        let usage = session.contextUsage
        XCTAssertEqual(usage.usedTokens, 50_000)
        XCTAssertEqual(usage.limitTokens, 100_000)
        XCTAssertEqual(usage.fraction ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(usage.lastOutputTokens, 100)
    }

    /// Model değişince eski sayım yeni paydaya vurulmaz.
    func testSelectModelClearsReportedUsage() async throws {
        let session = makeSession(
            usage: TurnTokenUsage(inputTokens: 50_000, outputTokens: 100)
        )
        session.applyCapabilities([capabilities()], normalizeConfiguration: false)

        let turn = session.submit("Hi")
        await turn?.value
        await waitForSettled(session)
        XCTAssertNotNil(session.lastTurnUsage)

        try session.selectModel(ProviderModelID("m2"))

        XCTAssertNil(session.lastTurnUsage)
        let usage = session.contextUsage
        XCTAssertNil(usage.usedTokens)
        XCTAssertNil(usage.fraction)
        XCTAssertEqual(usage.limitTokens, 200_000)
    }

    /// Bildirimler oturum boyu birikir (halka kartındaki "Total processed").
    func testTotalsAccumulateAcrossTurns() async {
        let session = makeSession(
            usage: TurnTokenUsage(inputTokens: 50_000, outputTokens: 100)
        )
        session.applyCapabilities([capabilities()], normalizeConfiguration: false)

        let turn = session.submit("Hi")
        await turn?.value
        await waitForSettled(session)

        XCTAssertEqual(session.totalProcessedTokens, 50_100)
        // Ömür boyu sayaç model değişiminde sıfırlanmaz.
        try? session.selectModel(ProviderModelID("m2"))
        XCTAssertEqual(session.totalProcessedTokens, 50_100)
        XCTAssertNil(session.lastTurnUsage)
    }

    /// Compact engeli düğmeyle aynı kararı verir.
    func testCompactionBlockerWithoutRuntime() {
        let bare = AgentSession(
            runtimes: [],
            state: AgentSessionState()
        )
        XCTAssertEqual(bare.compactionBlocker, .unavailable)
    }

    func testCompactionBlockerNothingToCompactWhenFitting() {
        let session = makeSession(
            usage: TurnTokenUsage(inputTokens: 50_000, outputTokens: 100)
        )
        XCTAssertEqual(session.compactionBlocker, .nothingToCompact)
    }

    /// Pencere bilinmiyorsa payda `nil`dir, bütçe tahmini konmaz.
    func testUnknownLimitMeansNilLimit() {
        let session = makeSession(
            usage: TurnTokenUsage(inputTokens: 50_000, outputTokens: 100)
        )

        let usage = session.contextUsage

        XCTAssertNil(usage.limitTokens)
        XCTAssertNil(usage.fraction)
    }
}

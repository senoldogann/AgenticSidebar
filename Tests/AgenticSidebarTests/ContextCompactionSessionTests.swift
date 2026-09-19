import XCTest

@testable import AgenticSidebar

/// Kırpma bildirimi disiplini + sıkıştırma orkestrasyonu: nag yalnız yeni
/// kayıpta kurulur, otomatik tur düşen ön eki özetleyip sunucu tarafını
/// döndürür, elle `/compact` aynı motordan geçer.
@MainActor
final class ContextCompactionSessionTests: XCTestCase {
    private actor Script {
        enum TurnOutcome {
            case succeed(assistantText: String)
            case fail
        }

        private var outcomes: [TurnOutcome]
        private var answers: [String]
        private(set) var queries: [SideQuestionQuery] = []
        private(set) var releasedSessions: [UUID] = []

        init(outcomes: [TurnOutcome] = [], answers: [String] = []) {
            self.outcomes = outcomes
            self.answers = answers
        }

        func nextOutcome() -> TurnOutcome {
            guard !outcomes.isEmpty else {
                return .succeed(assistantText: "")
            }
            return outcomes.removeFirst()
        }

        func nextAnswer() -> String {
            guard !answers.isEmpty else {
                return ""
            }
            return answers.removeFirst()
        }

        func recordQuery(_ query: SideQuestionQuery) {
            queries.append(query)
        }

        func recordRelease(_ sessionID: UUID) {
            releasedSessions.append(sessionID)
        }
    }

    private struct FakeRuntime: ProviderRuntime {
        let id = ProviderID("opencode")
        let script: Script

        func capabilities() async throws -> ProviderCapabilities {
            ProviderCapabilities(id: id, displayName: "Test", models: [])
        }

        func startStream(for request: ProviderRequest) async throws -> ProviderStream {
            switch await script.nextOutcome() {
            case .succeed(let assistantText):
                let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
                if !assistantText.isEmpty {
                    pair.continuation.yield(.assistantTextDelta(assistantText))
                }
                pair.continuation.yield(.completed)
                pair.continuation.finish()
                return ProviderStream(events: pair.stream)
            case .fail:
                throw ProviderRuntimeError.transport
            }
        }

        func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
            await script.recordQuery(query)
            let answer = await script.nextAnswer()
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            if !answer.isEmpty {
                pair.continuation.yield(.assistantTextDelta(answer))
            }
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }

        func releaseSession(_ sessionID: UUID) async {
            await script.recordRelease(sessionID)
        }
    }

    private func makeSession(script: Script) -> AgentSession {
        AgentSession(
            runtimes: [FakeRuntime(script: script)],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("opencode"),
                    modelID: ProviderModelID("test/model"),
                    variantID: nil
                )
            ),
            budget: TranscriptBudget(characterBudget: 1_000)
        )
    }

    private func runTurn(_ session: AgentSession, text: String) async {
        let turn = session.submit(text)
        await turn?.value
        _ = await waitFor { !session.isBusy }
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<600 {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Kırpma bildirimi yalnız kayıp BÜYÜDÜĞÜNDE kurulur: aynı kayıp her
    /// turda yeniden sunulmaz, yeni kayıp yine haber verilir.
    func testTrimNoticeFiresOnlyOnNewLoss() async {
        let userText = String(repeating: "x", count: 400)
        let assistantText = String(repeating: "y", count: 400)
        let script = Script(outcomes: [
            .succeed(assistantText: assistantText),
            .succeed(assistantText: assistantText),
            .fail,
            .succeed(assistantText: assistantText),
        ])
        let session = makeSession(script: script)

        await runTurn(session, text: userText)
        XCTAssertEqual(session.state.messages.count, 2)
        XCTAssertNil(session.state.notice)

        // Pencere taştı: 2 mesaj düştü, haber verilir.
        await runTurn(session, text: userText)
        XCTAssertEqual(session.state.notice, .transcriptTrimmed(droppedMessageCount: 2))
        session.dismissNotice()
        XCTAssertNil(session.state.notice)

        // Başarısız tur 4 mesaja düşürdü: yeni kayıp, yeniden haber verilir.
        await runTurn(session, text: userText)
        XCTAssertEqual(session.state.status, .failed)
        XCTAssertEqual(session.state.notice, .transcriptTrimmed(droppedMessageCount: 4))
        session.dismissNotice()

        // Kayıp aynı kaldı (4): nag kurulmaz.
        await runTurn(session, text: userText)
        XCTAssertNil(
            session.state.notice,
            "aynı kayıp her turda yeniden sunulmamalı"
        )
    }

    /// Otomatik tur düşen ön eki özetler, anlık görüntüye yazar ve sunucu
    /// tarafını döndürür; sonraki tur özeti taşır.
    func testAutoCompactionSummarizesAndRotates() async {
        let userText = String(repeating: "x", count: 400)
        let assistantText = String(repeating: "y", count: 400)
        let script = Script(
            outcomes: [
                .succeed(assistantText: assistantText),
                .succeed(assistantText: assistantText),
            ],
            answers: ["SUMMARY-ONE"]
        )
        let session = makeSession(script: script)

        await runTurn(session, text: userText)
        await runTurn(session, text: userText)

        // Rotasyon en son adımdır: buraya gelindiyse özet uygulanmış,
        // bildirim kurulmuş, anlık görüntü yazılmış demektir.
        let rotated = await waitFor { !(await script.releasedSessions).isEmpty }
        XCTAssertTrue(rotated, "düşen ön ek otomatik özetlenip sunucu tarafı dönmeli")
        XCTAssertEqual(session.contextSummary, "SUMMARY-ONE")
        XCTAssertEqual(session.snapshot().contextSummary, "SUMMARY-ONE")

        let queries = await script.queries
        XCTAssertEqual(queries.count, 1, "tek özet turu atılmalı")
        XCTAssertTrue(
            queries.first?.question.contains("User:") ?? false,
            "özet sorusu düşen turları taşımalı"
        )

        let released = await script.releasedSessions
        XCTAssertEqual(released, [session.id], "sunucu tarafı döndürülmeli")
        XCTAssertEqual(session.state.notice, .contextCompacted)
    }

    /// İkinci tur önceki özeti katlayarak büyütür (yuvarlanan özet).
    func testSecondCompactionFoldsPriorSummary() async {
        let userText = String(repeating: "x", count: 400)
        let assistantText = String(repeating: "y", count: 400)
        let script = Script(
            outcomes: [
                .succeed(assistantText: assistantText),
                .succeed(assistantText: assistantText),
                .succeed(assistantText: assistantText),
            ],
            answers: ["SUMMARY-ONE", "SUMMARY-TWO"]
        )
        let session = makeSession(script: script)

        await runTurn(session, text: userText)
        await runTurn(session, text: userText)
        _ = await waitFor { session.contextSummary == "SUMMARY-ONE" }
        await runTurn(session, text: userText)
        let rolled = await waitFor { session.contextSummary == "SUMMARY-TWO" }

        XCTAssertTrue(rolled, "yeni düşen ön ek ikinci özeti tetiklemeli")
        let queries = await script.queries
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(
            queries.last?.question.contains("SUMMARY-ONE") ?? false,
            "ikinci özet ilkini katlamalı"
        )
    }

    /// Sığan sohbette elle `/compact` iş yapmaz, gerekçesini söyler.
    func testManualCompactionWithNothingToCompact() async {
        let script = Script()
        let session = makeSession(script: script)
        await runTurn(session, text: "Hi")

        session.requestCompaction()

        XCTAssertEqual(
            session.state.notice,
            .compactionFailed(reason: .nothingToCompact)
        )
        let queries = await script.queries
        XCTAssertTrue(queries.isEmpty, "özetlenecek ön ek yoksa tur atılmaz")
    }

    /// Meşgul oturumda elle `/compact` turun üstüne binmez.
    func testManualCompactionWhileBusy() async {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let holding = HoldingRuntime(pair: pair.stream)
        let session = AgentSession(
            runtimes: [holding],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("opencode"),
                    modelID: ProviderModelID("test/model"),
                    variantID: nil
                )
            ),
            budget: TranscriptBudget(characterBudget: 1_000)
        )
        let turn = session.submit("Hold this turn open")
        _ = await waitFor { session.isBusy }
        XCTAssertTrue(session.isBusy)

        session.requestCompaction()

        XCTAssertEqual(
            session.state.notice,
            .compactionFailed(reason: .busy)
        )
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn?.value
    }

    private struct HoldingRuntime: ProviderRuntime {
        let id = ProviderID("opencode")
        let pair: AsyncThrowingStream<ProviderEvent, Error>

        func capabilities() async throws -> ProviderCapabilities {
            ProviderCapabilities(id: id, displayName: "Test", models: [])
        }

        func startStream(for request: ProviderRequest) async throws -> ProviderStream {
            ProviderStream(events: pair)
        }
    }
}

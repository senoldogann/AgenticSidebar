import Foundation
import XCTest

@testable import AgenticSidebar

/// Durum makinesi: mutlu yol `done`, kırmızı kapı `fixing`, bütçe aşımı ve
/// durdurma `failed`, yanlış faz çağrısı yok sayılır. Bütçe kapakları da burada
/// doğrulanır (motorun sahibidir).
final class GoalEngineTests: XCTestCase {
    private func makeEngine(
        maxIterations: Int = 5,
        maxDurationSeconds: TimeInterval = 3600,
        maxToolCalls: Int = 200
    ) -> GoalEngine {
        GoalEngine(
            objective: "Örnek hedef",
            budget: GoalBudget(
                maxIterations: maxIterations,
                maxDurationSeconds: maxDurationSeconds,
                maxToolCalls: maxToolCalls
            ),
            startedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + offset)
    }

    private func criteria(_ texts: String...) -> [AcceptanceCriterion] {
        texts.map { AcceptanceCriterion(id: UUID(), text: $0, isMet: false) }
    }

    // MARK: - Mutlu yol

    func testHappyPathReachesDone() {
        var engine = makeEngine()
        let list = criteria("bir", "iki")
        XCTAssertTrue(engine.begin(criteria: list, date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.didFinishBuild(date: date(3)))
        XCTAssertTrue(engine.didFinishVerification(buildSucceeded: true, testsSucceeded: true, date: date(4)))
        for item in list {
            XCTAssertTrue(engine.setCriterion(id: item.id, isMet: true, date: date(5)))
        }
        XCTAssertTrue(engine.didFinishReview(criticalOrHighFindings: 0, date: date(6)))
        XCTAssertEqual(engine.run.phase, .done)
        XCTAssertEqual(engine.run.iteration, 0)
        XCTAssertFalse(engine.run.log.isEmpty)
    }

    // MARK: - Düzeltme döngüsü

    func testRedBuildGoesToFixingThenDone() {
        var engine = makeEngine()
        let list = criteria("bir")
        XCTAssertTrue(engine.begin(criteria: list, date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.didFinishBuild(date: date(3)))
        XCTAssertTrue(engine.didFinishVerification(buildSucceeded: false, testsSucceeded: false, date: date(4)))
        XCTAssertTrue(engine.didFinishReview(criticalOrHighFindings: 0, date: date(5)))
        XCTAssertEqual(engine.run.phase, .fixing)
        XCTAssertEqual(engine.run.iteration, 1)
        XCTAssertTrue(engine.noteFix(date: date(6)))
        XCTAssertEqual(engine.run.phase, .building)
        XCTAssertTrue(engine.didFinishBuild(date: date(7)))
        XCTAssertTrue(engine.didFinishVerification(buildSucceeded: true, testsSucceeded: true, date: date(8)))
        XCTAssertTrue(engine.setCriterion(id: list[0].id, isMet: true, date: date(9)))
        XCTAssertTrue(engine.didFinishReview(criticalOrHighFindings: 0, date: date(10)))
        XCTAssertEqual(engine.run.phase, .done)
        XCTAssertEqual(engine.run.iteration, 1)
    }

    func testReviewFindingsGoToFixing() {
        var engine = makeEngine()
        let list = criteria("bir")
        XCTAssertTrue(engine.begin(criteria: list, date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.didFinishBuild(date: date(3)))
        XCTAssertTrue(engine.didFinishVerification(buildSucceeded: true, testsSucceeded: true, date: date(4)))
        XCTAssertTrue(engine.didFinishReview(criticalOrHighFindings: 2, date: date(5)))
        XCTAssertEqual(engine.run.phase, .fixing)
        XCTAssertNotEqual(engine.run.phase, .done)
    }

    // MARK: - Bütçe

    func testIterationBudgetStopsTheLoop() {
        var engine = makeEngine(maxIterations: 0)
        let list = criteria("bir")
        XCTAssertTrue(engine.begin(criteria: list, date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.didFinishBuild(date: date(3)))
        XCTAssertTrue(engine.didFinishVerification(buildSucceeded: false, testsSucceeded: false, date: date(4)))
        XCTAssertTrue(engine.didFinishReview(criticalOrHighFindings: 0, date: date(5)))
        XCTAssertEqual(engine.run.phase, .failed)
        XCTAssertEqual(engine.run.failureReason, .budgetExceeded(detail: "budget exceeded after 1 iterations"))
    }

    func testToolCallBudgetStopsTheRun() {
        var engine = makeEngine(maxToolCalls: 3)
        engine.addToolCalls(2, date: date(1))
        XCTAssertNotEqual(engine.run.phase, .failed)
        engine.addToolCalls(2, date: date(2))
        XCTAssertEqual(engine.run.phase, .failed)
        XCTAssertEqual(
            engine.run.failureReason,
            .budgetExceeded(detail: "tool call budget exceeded at 4 calls")
        )
    }

    func testNonPositiveToolCallsAreIgnored() {
        var engine = makeEngine(maxToolCalls: 3)
        engine.addToolCalls(2, date: date(1))
        engine.addToolCalls(0, date: date(2))
        engine.addToolCalls(-5, date: date(3))
        XCTAssertNotEqual(engine.run.phase, .failed)
        // Sayaç geri sarmadı: 2'de kaldı, bütçe aşılmadı.
        engine.addToolCalls(1, date: date(4))
        XCTAssertNotEqual(engine.run.phase, .failed)
        engine.addToolCalls(1, date: date(5))
        XCTAssertEqual(engine.run.phase, .failed)
    }

    func testDurationBudgetIsReported() {
        let engine = makeEngine(maxDurationSeconds: 60)
        XCTAssertFalse(engine.isOverBudget(now: date(30)))
        XCTAssertTrue(engine.isOverBudget(now: date(61)))
    }

    func testBudgetCapsAreConjunctive() {
        let budget = GoalBudget(maxIterations: 2, maxDurationSeconds: 100, maxToolCalls: 10)
        XCTAssertFalse(budget.isExceeded(iterations: 2, elapsedSeconds: 100, toolCalls: 10))
        XCTAssertTrue(budget.isExceeded(iterations: 3, elapsedSeconds: 100, toolCalls: 10))
        XCTAssertTrue(budget.isExceeded(iterations: 2, elapsedSeconds: 101, toolCalls: 10))
        XCTAssertTrue(budget.isExceeded(iterations: 2, elapsedSeconds: 100, toolCalls: 11))
    }

    // MARK: - Duraklat / durdur

    func testPauseAndResumeRoundTrip() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.pause(date: date(2)))
        XCTAssertEqual(engine.run.phase, .paused)
        XCTAssertTrue(engine.resume(date: date(3)))
        XCTAssertEqual(engine.run.phase, .planning)
    }

    func testPauseFreezesTheDurationBudget() {
        var engine = makeEngine(maxDurationSeconds: 60)
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.pause(date: date(10)))
        XCTAssertTrue(engine.resume(date: date(50)))
        // 70. saniyede duvar saati 70 ama duraklatma (40 sn) düşer: 30 < 60.
        XCTAssertFalse(engine.isOverBudget(now: date(70)))
        // 110. saniyede etkin süre 70 > 60.
        XCTAssertTrue(engine.isOverBudget(now: date(110)))
    }

    func testStopCancelsTheRun() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.stop(date: date(2)))
        XCTAssertEqual(engine.run.phase, .failed)
        XCTAssertEqual(engine.run.failureReason, .cancelledByUser)
    }

    func testTerminalRunIgnoresFurtherEvents() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.stop(date: date(2)))
        XCTAssertFalse(engine.pause(date: date(3)))
        XCTAssertFalse(engine.setCriterion(id: UUID(), isMet: true, date: date(4)))
        engine.addToolCalls(10, date: date(5))
        XCTAssertEqual(engine.run.failureReason, .cancelledByUser)
    }

    // MARK: - Geçersiz geçişler

    func testEmptyCriteriaFailsFast() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: [], date: date(1)))
        XCTAssertEqual(engine.run.phase, .failed)
        XCTAssertEqual(
            engine.run.failureReason,
            .unrecoverable(detail: "decomposition produced no acceptance criteria")
        )
    }

    func testOutOfOrderEventsAreIgnored() {
        var engine = makeEngine()
        XCTAssertFalse(engine.didFinishBuild(date: date(1)))
        XCTAssertFalse(engine.didFinishReview(criticalOrHighFindings: 0, date: date(2)))
        XCTAssertFalse(engine.noteFix(date: date(3)))
        XCTAssertEqual(engine.run.phase, .decomposing)
    }

    func testUnknownCriterionIsRejected() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertFalse(engine.setCriterion(id: UUID(), isMet: true, date: date(2)))
    }

    // MARK: - Geçen süre

    func testElapsedAccruesFromStart() {
        let engine = makeEngine()
        XCTAssertEqual(engine.elapsedSeconds(now: date(0)), 0)
        XCTAssertEqual(engine.elapsedSeconds(now: date(90)), 90)
    }

    func testElapsedFreezesWhilePaused() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.pause(date: date(10)))
        // Duraklatma sürerken duvar saati işler ama sayaç 10'da donar.
        XCTAssertEqual(engine.elapsedSeconds(now: date(40)), 10)
        XCTAssertTrue(engine.resume(date: date(50)))
        // Devam edince kaldığı yerden sayar: 50–70 arası 20 sn daha.
        XCTAssertEqual(engine.elapsedSeconds(now: date(70)), 30)
    }

    func testElapsedFreezesWhenTerminal() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.stop(date: date(25)))
        // Bitişten sonra sorulsa da sayaç terminal anında donar.
        XCTAssertEqual(engine.elapsedSeconds(now: date(1_000)), 25)
    }

    func testElapsedNeverGoesNegative() {
        let engine = makeEngine()
        XCTAssertEqual(engine.elapsedSeconds(now: date(-5)), 0)
    }

    // MARK: - Hedef güncelleme ve oto-onay

    func testUpdateObjectiveChangesTarget() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.updateObjective("Güncel hedef", date: date(2)))
        XCTAssertEqual(engine.run.objective, "Güncel hedef")
        XCTAssertFalse(engine.updateObjective("   ", date: date(3)))
        XCTAssertEqual(engine.run.objective, "Güncel hedef")
    }

    func testMarkAllCriteriaMet() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir", "iki"), date: date(1)))
        XCTAssertTrue(engine.markAllCriteriaMet(date: date(2)))
        XCTAssertEqual(engine.run.unmetCriteriaCount, 0)
        XCTAssertFalse(engine.markAllCriteriaMet(date: date(3)), "Zaten hepsi met ise tekrar işlem yapmamalı")
    }

    // MARK: - Tur zaman aşımı

    func testNoteTurnTimeoutRetriesInSamePhase() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.noteTurnTimeout(date: date(3)))
        XCTAssertEqual(engine.run.phase, .building, "Stall fazı değiştirmemeli")
        XCTAssertEqual(engine.run.iteration, 1)
        XCTAssertFalse(engine.run.isTerminal)
    }

    func testNoteTurnTimeoutFailsWhenBudgetExhausted() {
        var engine = GoalEngine(
            objective: "Hedef",
            budget: GoalBudget(maxIterations: 1, maxDurationSeconds: 3_600, maxToolCalls: 300),
            startedAt: date(0)
        )
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.noteTurnTimeout(date: date(3)))
        XCTAssertFalse(engine.run.isTerminal)
        XCTAssertFalse(engine.noteTurnTimeout(date: date(4)), "Bütçe bitince yeniden deneme yok")
        XCTAssertEqual(engine.run.phase, .failed)
    }

    func testNoteTransientTurnErrorRetriesInSamePhase() {
        var engine = makeEngine()
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertTrue(engine.didFinishPlan(date: date(2)))
        XCTAssertTrue(engine.noteTransientTurnError(detail: "transportFailure", date: date(3)))
        XCTAssertEqual(engine.run.phase, .building, "Geçici hata fazı değiştirmemeli")
        XCTAssertEqual(engine.run.iteration, 1)
        XCTAssertFalse(engine.run.isTerminal)
    }

    func testNoteTransientTurnErrorFailsWhenBudgetExhausted() {
        var engine = GoalEngine(
            objective: "Hedef",
            budget: GoalBudget(maxIterations: 0, maxDurationSeconds: 3_600, maxToolCalls: 300),
            startedAt: date(0)
        )
        XCTAssertTrue(engine.begin(criteria: criteria("bir"), date: date(1)))
        XCTAssertFalse(engine.noteTransientTurnError(detail: "rateLimited", date: date(2)), "Bütçe bitince yeniden deneme yok")
        XCTAssertEqual(engine.run.phase, .failed)
        if case .budgetExceeded = engine.run.failureReason {
        } else {
            XCTFail("expected budgetExceeded")
        }
    }
}

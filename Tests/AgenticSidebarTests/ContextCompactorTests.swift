import Foundation
import XCTest

@testable import AgenticSidebar

/// Bağlam sıkıştırma planı ve özet bloğu: pencere dışına düşen, henüz
/// özetlenmemiş ön ek bulunur; özet turunun sorusu ve istek bloğu saf
/// üretilir. Orkestrasyon (`AgentSession`) burada test edilmez.
final class ContextCompactorTests: XCTestCase {
    private func messages(_ texts: String...) -> [ChatMessage] {
        texts.enumerated().map { index, text in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: text
            )
        }
    }

    /// Pencereye sığan sohbette kapsanacak ön ek yoktur.
    func testFittingConversationNeedsNoPlan() {
        let plan = ContextCompactor.plan(messages: messages("Hi", "Hello", "How?", "Fine"))
        XCTAssertNil(plan, "düşen mesaj yoksa özet turu da yok")
    }

    /// Düşen ön ek, okuma sırasıyla plana girer.
    func testDroppedPrefixBecomesThePlan() throws {
        // Tabanda 1_000 karakter vardır; 6x300 karakterlik tur pencereden taşar.
        let all = messages(
            String(repeating: "a", count: 300),
            String(repeating: "b", count: 300),
            String(repeating: "c", count: 300),
            String(repeating: "d", count: 300),
            String(repeating: "e", count: 300),
            String(repeating: "f", count: 300)
        )
        let budget = TranscriptBudget(characterBudget: 1_000)
        let kept = Set(budget.select(from: all).messages.map(\.id))
        XCTAssertFalse(kept.count == all.count, "ön koşul: pencere taşmalı")

        let planned = try XCTUnwrap(
            ContextCompactor.plan(messages: all, budget: budget)
        )
        XCTAssertFalse(planned.staleMessages.isEmpty)
        XCTAssertTrue(
            planned.staleMessages.allSatisfy { !kept.contains($0.id) },
            "planda yalnız pencereden düşenler olur"
        )
        XCTAssertEqual(
            planned.staleMessages.map(\.text),
            all.filter { !kept.contains($0.id) }.map(\.text),
            "ön ek okuma sırasını korur"
        )
    }

    /// Daha önce özetlenen aralık tekrar plana girmez.
    func testCoveredPrefixIsSkipped() throws {
        let all = messages(
            String(repeating: "a", count: 300),
            String(repeating: "b", count: 300),
            String(repeating: "c", count: 300),
            String(repeating: "d", count: 300),
            String(repeating: "e", count: 300),
            String(repeating: "f", count: 300)
        )
        let budget = TranscriptBudget(characterBudget: 1_000)
        let first = try XCTUnwrap(
            ContextCompactor.plan(messages: all, budget: budget)
        )
        let covered = try XCTUnwrap(first.staleMessages.last?.id)

        let second = ContextCompactor.plan(
            messages: all,
            budget: budget,
            summarizedThroughMessageID: covered
        )
        XCTAssertNil(second, "kapsanan aralık yeniden özetlenmez")
    }

    /// Özet sorusu önceki özeti ve ham ön eki taşır.
    func testSummarizationPromptFoldsPriorSummary() {
        let prompt = ContextCompactor.summarizationPrompt(
            priorSummary: "We use SQLite.",
            staleMessages: messages("Pick a database", "SQLite it is")
        )
        XCTAssertTrue(prompt.contains("We use SQLite."))
        XCTAssertTrue(prompt.contains("User: Pick a database"))
        XCTAssertTrue(prompt.contains("Assistant: SQLite it is"))
        XCTAssertTrue(prompt.contains("ONLY"))
    }

    /// Dev özet yanıtı tavana indirilir.
    func testBoundSummaryCapsOversizedText() {
        let long = String(repeating: "x", count: ContextCompactor.maximumSummaryCharacters + 10)
        let bounded = ContextCompactor.boundSummary(long)
        XCTAssertLessThanOrEqual(
            bounded.count,
            ContextCompactor.maximumSummaryCharacters + 1
        )
        XCTAssertEqual(
            ContextCompactor.boundSummary("  tidy  "),
            "tidy"
        )
    }

    /// Boş özet mesaj üretmez.
    func testSummaryMessageIsNilWhenEmpty() {
        XCTAssertNil(ContextCompactor.summaryMessage("   "))
        let message = try? XCTUnwrap(ContextCompactor.summaryMessage("Keep this."))
        XCTAssertEqual(message?.role, .user)
        XCTAssertTrue(message?.text.contains("Keep this.") ?? false)
    }
}

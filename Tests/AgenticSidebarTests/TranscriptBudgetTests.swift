import Foundation
import XCTest
@testable import AgenticSidebar

final class TranscriptBudgetTests: XCTestCase {
    func testKeepsTheNewestMessagesAndReportsWhatWasDropped() {
        let budget = TranscriptBudget(characterBudget: 1_000)
        let messages = [
            ChatMessage(role: .user, text: String(repeating: "a", count: 500)),
            ChatMessage(role: .assistant, text: String(repeating: "b", count: 500)),
            ChatMessage(role: .user, text: "newest")
        ]

        let selection = budget.select(from: messages)

        XCTAssertEqual(selection.messages.map(\.text), ["newest"])
        XCTAssertEqual(selection.droppedMessageCount, 2)
    }

    func testAlwaysKeepsTheNewestMessageEvenWhenItAloneExceedsTheBudget() {
        let budget = TranscriptBudget(characterBudget: 1_000)
        let huge = String(repeating: "x", count: 50_000)
        let messages = [
            ChatMessage(role: .user, text: "old"),
            ChatMessage(role: .assistant, text: String(repeating: "y", count: 5_000)),
            ChatMessage(role: .user, text: huge)
        ]

        let selection = budget.select(from: messages)

        XCTAssertEqual(selection.messages.count, 1)
        XCTAssertEqual(selection.messages.first?.text, huge)
    }

    func testAttachmentPathsCountTowardTheBudget() {
        let budget = TranscriptBudget(characterBudget: 900)
        let messages = [
            ChatMessage(
                role: .user,
                text: String(repeating: "a", count: 200),
                attachmentPaths: [String(repeating: "p", count: 900)]
            ),
            ChatMessage(role: .assistant, text: "answer"),
            ChatMessage(role: .user, text: "follow up")
        ]

        let selection = budget.select(from: messages)

        XCTAssertEqual(selection.messages.map(\.text), ["follow up"])
        XCTAssertEqual(selection.droppedMessageCount, 2)
    }

    func testWindowStartsOnAUserTurnWhenPossible() {
        let budget = TranscriptBudget(characterBudget: 100_000)
        let messages = [
            ChatMessage(role: .assistant, text: "stray reply"),
            ChatMessage(role: .user, text: "question"),
            ChatMessage(role: .assistant, text: "answer")
        ]

        let selection = budget.select(from: messages)

        XCTAssertEqual(selection.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(selection.droppedMessageCount, 1)
    }

    func testShortTranscriptIsReturnedUnchanged() {
        let budget = TranscriptBudget()
        let messages = [
            ChatMessage(role: .user, text: "hello"),
            ChatMessage(role: .assistant, text: "hi")
        ]

        let selection = budget.select(from: messages)

        XCTAssertEqual(selection.messages, messages)
        XCTAssertEqual(selection.droppedMessageCount, 0)
    }

    func testEmptyTranscriptSelectsNothing() {
        let selection = TranscriptBudget().select(from: [])

        XCTAssertTrue(selection.messages.isEmpty)
        XCTAssertEqual(selection.droppedMessageCount, 0)
    }

    func testApproximateTokenCountUsesFourCharactersPerToken() {
        XCTAssertEqual(TranscriptBudget.approximateTokenCount(for: "abcd"), 1)
        XCTAssertEqual(TranscriptBudget.approximateTokenCount(for: "abcde"), 2)
        XCTAssertEqual(TranscriptBudget.approximateTokenCount(for: ""), 0)
    }

    func testBudgetNeverDropsBelowAMinimumUsefulWindow() {
        XCTAssertEqual(TranscriptBudget(characterBudget: 10).characterBudget, 1_000)
    }
}

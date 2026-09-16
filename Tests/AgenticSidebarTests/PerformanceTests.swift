import Foundation
import XCTest
@testable import AgenticSidebar

/// The two things that made a long draft or a long conversation feel slow were
/// work proportional to *all* of the text, done per keystroke and per frame.
///
/// These tests pin the properties rather than the timings: a bounded scan stays
/// bounded, a memoized lookup is not recomputed, and a cache keeps its promise.
/// The timing assertions that remain are generous — they exist to catch a return
/// to walking the whole input, not to measure the machine.
final class ComposerDraftMetricsTests: XCTestCase {
    func testWhitespaceOnlyDraftsHaveNoContent() {
        XCTAssertFalse(ComposerDraftMetrics.hasContent(""))
        XCTAssertFalse(ComposerDraftMetrics.hasContent("   "))
        XCTAssertFalse(ComposerDraftMetrics.hasContent("\n\t  \n"))
        XCTAssertTrue(ComposerDraftMetrics.hasContent(" x "))
        XCTAssertTrue(ComposerDraftMetrics.hasContent("🙂"))
    }

    func testOnlyABoundedPrefixIsMeasuredForHeight() {
        let document = String(repeating: "a", count: 500_000)

        let measured = ComposerDraftMetrics.measuredPrefix(of: document)

        XCTAssertEqual(
            measured.utf8.count,
            ComposerDraftMetrics.heightMeasurementPrefixBytes,
            "A huge paste must not be laid out in full on every keystroke"
        )
    }

    func testAShortDraftIsMeasuredWhole() {
        XCTAssertEqual(ComposerDraftMetrics.measuredPrefix(of: "hello"), "hello")
        XCTAssertEqual(ComposerDraftMetrics.measuredPrefix(of: ""), "")
    }

    func testMeasuringAPastedDocumentIsFast() {
        let document = String(repeating: "word ", count: 200_000)

        let started = Date()
        for _ in 0..<50 {
            _ = ComposerDraftMetrics.measuredPrefix(of: document)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5, "50 measurements of a 1 MB draft must not take half a second")
    }

    func testTheEditorHeightIsCapped() {
        XCTAssertEqual(ComposerDraftMetrics.maximumMeasuredHeight, 104)
    }

    func testTheFingerprintNoticesBothEndsOfADraft() {
        let base = String(repeating: "x", count: 5_000)

        XCTAssertNotEqual(
            ComposerDraftMetrics.fingerprint(of: base),
            ComposerDraftMetrics.fingerprint(of: base + "y")
        )
        XCTAssertNotEqual(
            ComposerDraftMetrics.fingerprint(of: base),
            ComposerDraftMetrics.fingerprint(of: "y" + base)
        )
        XCTAssertEqual(
            ComposerDraftMetrics.fingerprint(of: base),
            ComposerDraftMetrics.fingerprint(of: base)
        )
    }
}

final class ExtensionTriggerScanTests: XCTestCase {
    func testATriggerAfterALargePasteIsStillFound() throws {
        let pasted = String(repeating: "lorem ipsum dolor sit amet ", count: 40_000)
        let draft = pasted + "@git"

        let trigger = try XCTUnwrap(ExtensionTrigger.detected(in: draft))

        XCTAssertEqual(trigger.query, "git")
        XCTAssertEqual(trigger.kinds, [.mcp, .plugin])
        XCTAssertEqual(String(draft[trigger.tokenRange]), "@git")
    }

    func testFindingATriggerInALargeDraftIsBoundedWork() {
        let draft = String(repeating: "text ", count: 400_000)  // ~2 MB

        let started = Date()
        for _ in 0..<200 {
            _ = ExtensionTrigger.detected(in: draft)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            1.0,
            "200 scans of a 2 MB draft must not take a second; a full scan would"
        )
    }

    func testAWordLongerThanTheWindowIsNotOfferedAsATrigger() {
        let draft = "@" + String(repeating: "a", count: ExtensionTrigger.maximumTailLength + 10)

        XCTAssertNil(ExtensionTrigger.detected(in: draft))
    }

    func testWhitespaceInsideTheWindowEndsTheToken() {
        let draft = "look at @git and then"

        XCTAssertNil(
            ExtensionTrigger.detected(in: draft),
            "The word being typed is “then”, not the earlier mention"
        )
    }
}

@MainActor
final class TranscriptIndexTests: XCTestCase {
    func testTheRailCoversTheUserMessagesInOrder() {
        let index = TranscriptIndex(
            promptItems: TranscriptIndex.promptItems(
                for: [
                    ChatMessage(role: .user, text: "first question"),
                    ChatMessage(role: .assistant, text: "answer"),
                    ChatMessage(role: .user, text: "second question")
                ],
                maximumPromptCount: 60
            ),
            groupsByAnchor: [:]
        )

        XCTAssertEqual(index.promptItems.map(\.title), ["first question", "second question"])
    }

    func testTheRailKeepsOnlyTheMostRecentPrompts() {
        let messages = (1...80).map { ChatMessage(role: .user, text: "prompt \($0)") }

        let items = TranscriptIndex.promptItems(for: messages, maximumPromptCount: 60)

        XCTAssertEqual(items.count, 60)
        XCTAssertEqual(items.first?.title, "prompt 21")
        XCTAssertEqual(items.last?.title, "prompt 80")
    }

    func testATitleIsTheFirstLineAndIsBoundedInLength() {
        XCTAssertEqual(TranscriptIndex.railTitle(for: "line one\nline two"), "line one")
        XCTAssertEqual(TranscriptIndex.railTitle(for: "   \n "), "Attachment")

        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(TranscriptIndex.railTitle(for: long).count, 60)
    }

    func testTheActivityGroupOfAMessageIsFoundByAnchor() {
        let anchor = UUID()
        let group = AgentTurnActivityGroup(id: UUID(), anchorMessageID: anchor, activities: [])

        let index = TranscriptIndex(
            promptItems: [],
            groupsByAnchor: TranscriptIndex.groupsByAnchor([group])
        )

        XCTAssertEqual(index.activityGroup(after: anchor)?.id, group.id)
        XCTAssertNil(index.activityGroup(after: UUID()))
    }

    func testStreamingAssistantTextDoesNotRebuildTheIndex() {
        let cache = TranscriptIndexCache()
        var messages = [
            ChatMessage(role: .user, text: "explain the parser"),
            ChatMessage(role: .assistant, text: "The")
        ]

        _ = cache.index(messages: messages, activityGroups: [], maximumPromptCount: 60)
        let promptRebuildsAfterFirstPass = cache.promptRebuilds

        // Twenty-five frames of a streaming answer.
        for index in 1...25 {
            messages[1].text = String(repeating: "token ", count: index)
            _ = cache.index(messages: messages, activityGroups: [], maximumPromptCount: 60)
        }

        XCTAssertEqual(
            cache.promptRebuilds,
            promptRebuildsAfterFirstPass,
            "The rail titles depend on user messages, which do not stream"
        )
    }

    func testANewPromptRebuildsTheRailAndAnActivityDoesNotRebuildItAgain() {
        let cache = TranscriptIndexCache()
        var messages = [ChatMessage(role: .user, text: "one")]

        _ = cache.index(messages: messages, activityGroups: [], maximumPromptCount: 60)
        XCTAssertEqual(cache.promptRebuilds, 1)
        XCTAssertEqual(cache.groupRebuilds, 1)

        messages.append(ChatMessage(role: .user, text: "two"))
        let index = cache.index(messages: messages, activityGroups: [], maximumPromptCount: 60)

        XCTAssertEqual(cache.promptRebuilds, 2)
        XCTAssertEqual(cache.groupRebuilds, 1, "Nothing about the activities changed")
        XCTAssertEqual(index.promptItems.map(\.title), ["one", "two"])
    }

    func testAnActivityStartingRebuildsOnlyTheGroupHalf() {
        let cache = TranscriptIndexCache()
        let messages = [ChatMessage(role: .user, text: "one")]

        _ = cache.index(messages: messages, activityGroups: [], maximumPromptCount: 60)

        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: messages[0].id,
            activities: [
                AgentActivity(
                    id: ProviderActivityID(UUID().uuidString),
                    kind: .thinking,
                    phase: .running
                )
            ]
        )
        let index = cache.index(
            messages: messages,
            activityGroups: [group],
            maximumPromptCount: 60
        )

        XCTAssertEqual(cache.groupRebuilds, 2)
        XCTAssertEqual(cache.promptRebuilds, 1)
        XCTAssertEqual(index.activityGroup(after: messages[0].id)?.id, group.id)
    }
}

@MainActor
final class RelativeTimestampTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        RelativeTimestamp.reset()
    }

    override func tearDown() async throws {
        RelativeTimestamp.reset()
        try await super.tearDown()
    }

    func testTheSameMinuteIsFormattedOnce() {
        // Aligned to a bucket boundary, which is the condition being tested.
        let base = RelativeTimestamp.bucket(Date(timeIntervalSince1970: 1_700_000_000))

        let first = RelativeTimestamp.text(for: base)
        let second = RelativeTimestamp.text(for: base.addingTimeInterval(20))
        let third = RelativeTimestamp.text(for: base.addingTimeInterval(59))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third)
        XCTAssertEqual(RelativeTimestamp.cachedEntryCount, 1)
        XCTAssertFalse(first.isEmpty)
    }

    func testANewMinuteIsANewEntry() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        _ = RelativeTimestamp.text(for: base)
        _ = RelativeTimestamp.text(for: base.addingTimeInterval(90))

        XCTAssertEqual(RelativeTimestamp.cachedEntryCount, 2)
    }

    func testTheCacheIsBounded() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for minute in 0...(RelativeTimestamp.maximumCachedEntries + 20) {
            _ = RelativeTimestamp.text(
                for: base.addingTimeInterval(Double(minute) * 120)
            )
        }

        XCTAssertLessThanOrEqual(
            RelativeTimestamp.cachedEntryCount,
            RelativeTimestamp.maximumCachedEntries
        )
    }
}

@MainActor
final class MarkdownParseStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        MarkdownParseStore.shared.reset()
    }

    override func tearDown() async throws {
        MarkdownParseStore.shared.reset()
        try await super.tearDown()
    }

    func testTheSameTextIsParsedOnceEvenByANewViewInstance() {
        let markdown = "# Heading\n\nSome *body* text."

        let first = MarkdownParseCache()
        _ = first.blocks(for: markdown, allowsPlanDocuments: true)
        let missesAfterFirstParse = MarkdownParseStore.shared.misses

        // A conversation switch recreates the row, so a fresh cache asks again.
        let second = MarkdownParseCache()
        let blocks = second.blocks(for: markdown, allowsPlanDocuments: true)

        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(
            MarkdownParseStore.shared.misses,
            missesAfterFirstParse,
            "Returning to a conversation must not re-parse its messages"
        )
        XCTAssertGreaterThan(MarkdownParseStore.shared.hits, 0)
    }

    func testThePerViewCacheStillAnswersWithoutTouchingTheStore() {
        let markdown = "A paragraph."
        let cache = MarkdownParseCache()

        _ = cache.blocks(for: markdown, allowsPlanDocuments: true)
        let hitsAfterFirst = MarkdownParseStore.shared.hits

        _ = cache.blocks(for: markdown, allowsPlanDocuments: true)
        _ = cache.blocks(for: markdown, allowsPlanDocuments: true)

        XCTAssertEqual(MarkdownParseStore.shared.hits, hitsAfterFirst)
    }

    func testChangingTextReparsesAndKeepsBothVersions() {
        let cache = MarkdownParseCache()
        let first = cache.blocks(for: "one", allowsPlanDocuments: true)
        let second = cache.blocks(for: "one two", allowsPlanDocuments: true)

        XCTAssertNotEqual(first.count, 0)
        XCTAssertNotEqual(second.count, 0)
        XCTAssertNotNil(MarkdownParseStore.shared.blocks(for: "one", allowsPlanDocuments: true))
        XCTAssertNotNil(MarkdownParseStore.shared.blocks(for: "one two", allowsPlanDocuments: true))
    }

    func testPlanRecognitionIsPartOfTheCacheKey() {
        let markdown = "```plan\n1. do the thing\n```"
        let cache = MarkdownParseCache()

        _ = cache.blocks(for: markdown, allowsPlanDocuments: true)

        XCTAssertNotNil(
            MarkdownParseStore.shared.blocks(for: markdown, allowsPlanDocuments: true)
        )
        XCTAssertNil(
            MarkdownParseStore.shared.blocks(for: markdown, allowsPlanDocuments: false),
            "A body that renders as a plan document must not be reused inside one"
        )
    }

    func testTheStoreIsBounded() {
        let store = MarkdownParseStore.shared

        for index in 0..<(MarkdownParseStore.maximumEntries + 40) {
            store.store(
                parseMarkdownBlocks(from: "body \(index)", allowsPlanDocuments: true),
                for: "body \(index)",
                allowsPlanDocuments: true
            )
        }

        let retained = (0..<(MarkdownParseStore.maximumEntries + 40)).filter {
            store.blocks(for: "body \($0)", allowsPlanDocuments: true) != nil
        }

        XCTAssertLessThanOrEqual(
            retained.count,
            MarkdownParseStore.maximumEntries,
            "The cache has to forget, or a long session would hold every message's blocks"
        )
        XCTAssertFalse(
            retained.isEmpty,
            "The most recent entries are the ones worth keeping"
        )
    }
}

import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class ContextPersistenceTests: XCTestCase {
    func testQueuedPromptsSurviveASnapshotRoundTrip() throws {
        let sessionID = UUID()
        let queued = QueuedPrompt(text: "Queued work", attachmentPaths: ["/tmp/a.md"])
        let snapshot = SessionSnapshot(
            id: sessionID,
            createdAt: Date(),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-test"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "First")],
            activityGroups: [],
            queuedPrompts: [queued]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.queuedPrompts, [queued])

        let restored = AgentSession(runtimes: [], snapshot: decoded)
        XCTAssertEqual(restored.queuedPrompts, [queued])
    }

    func testOldArchivesWithoutAQueueStillDecode() throws {
        let payload = """
        {"id":"\(UUID().uuidString)","createdAt":"2026-09-16T12:00:00Z","messages":[],"activityGroups":[]}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionSnapshot.self, from: payload)
        XCTAssertTrue(decoded.queuedPrompts.isEmpty)
    }

    func testRestoredQueueIsCapped() {
        let sessionID = UUID()
        let snapshot = SessionSnapshot(
            id: sessionID,
            createdAt: Date(),
            configuration: nil,
            messages: [],
            activityGroups: [],
            queuedPrompts: (0..<100).map { QueuedPrompt(text: "Work \($0)") }
        )

        let restored = AgentSession(runtimes: [], snapshot: snapshot)
        XCTAssertEqual(restored.queuedPrompts.count, AgentSession.maximumQueuedPrompts)
    }

    func testQueueMutationsMarkTheSessionForSaving() {
        let queued = QueuedPrompt(text: "Waiting")
        let session = AgentSession(
            runtimes: [],
            snapshot: SessionSnapshot(
                id: UUID(),
                createdAt: Date(),
                configuration: nil,
                messages: [],
                activityGroups: [],
                queuedPrompts: [queued]
            )
        )
        var saveCount = 0
        session.onPersistentChange = { saveCount += 1 }

        // Queue changes live outside `state`, so each mutation must announce
        // itself; otherwise a quit mid-turn loses the waiting messages.
        session.removeQueuedPrompt(queued.id)
        XCTAssertEqual(saveCount, 1)

        session.clearQueuedPrompts()
        XCTAssertEqual(saveCount, 1, "clearing an empty queue writes nothing")

        _ = session.updateQueuedPrompt(UUID(), text: "missing")
        XCTAssertEqual(saveCount, 1, "a no-op update writes nothing")
    }
}

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    func testDraftRoundTripsThroughTheStore() {
        let store = ComposerDraftStore()
        let sessionID = UUID()

        XCTAssertNil(store.storedDraft(for: sessionID))

        store.update(sessionID: sessionID, text: "Unsent thought", attachmentPaths: ["/tmp/x.md"])
        XCTAssertEqual(store.storedDraft(for: sessionID)?.text, "Unsent thought")
        XCTAssertEqual(store.storedDraft(for: sessionID)?.attachmentPaths, ["/tmp/x.md"])

        store.clear(sessionID: sessionID)
        XCTAssertNil(store.storedDraft(for: sessionID))
    }

    func testEmptyDraftsAreNotKept() {
        let store = ComposerDraftStore()
        let sessionID = UUID()

        store.update(sessionID: sessionID, text: "   \n  ", attachmentPaths: [])
        XCTAssertNil(store.storedDraft(for: sessionID))
    }

    func testDraftsOfRemovedSessionsAreDiscarded() {
        let store = ComposerDraftStore()
        let kept = UUID()
        let removed = UUID()

        store.update(sessionID: kept, text: "Keep me", attachmentPaths: [])
        store.update(sessionID: removed, text: "Drop me", attachmentPaths: [])
        store.discardSessions(notIn: [kept])

        XCTAssertNotNil(store.storedDraft(for: kept))
        XCTAssertNil(store.storedDraft(for: removed))
    }

    func testDraftsSurviveAFlushAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sessionID = UUID()
        let fileURL = directory.appendingPathComponent("drafts.json")
        let writer = ComposerDraftStore(
            drafts: [
                sessionID.uuidString: ComposerStoredDraft(
                    text: "Survive me",
                    attachmentPaths: [],
                    updatedAt: Date()
                )
            ],
            fileURL: fileURL
        )
        await writer.flush()

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            [String: ComposerStoredDraft].self,
            from: data
        )
        XCTAssertEqual(decoded[sessionID.uuidString]?.text, "Survive me")
    }
}

import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class SessionPersistenceTests: XCTestCase {
    func testSessionsAndSelectionSurviveARelaunch() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtime = makeRuntime()
        let service = AgentSessionService(runtimes: [runtime], archiveStore: store)
        await service.refreshCapabilities()

        let restoredID = service.activeSessionID
        let turn = try XCTUnwrap(service.submit("Remember this"))
        await turn.value

        service.createSession()
        XCTAssertEqual(service.sessions.count, 2)
        service.selectSession(restoredID)
        await service.saveNow()

        let relaunched = AgentSessionService(runtimes: [runtime], archiveStore: store)

        XCTAssertEqual(relaunched.activeSessionID, restoredID)
        XCTAssertEqual(relaunched.sessions.count, 1, "Sessions without messages are not restored")
        XCTAssertEqual(relaunched.state.messages.map(\.text), ["Remember this"])
        XCTAssertEqual(relaunched.state.status, .idle, "A running turn cannot outlive the process")
        XCTAssertNil(relaunched.state.error)
        XCTAssertEqual(relaunched.state.configuration?.providerID, ProviderID("alpha"))
        XCTAssertNotNil(
            relaunched.sessionList.first?.lastMessageAt,
            "A restored conversation has no completed turn but must still report a real timestamp"
        )
    }

    func testAnEmptySessionStillRestoresTheSelectedConfiguration() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtime = makeRuntime()
        let service = AgentSessionService(
            runtimes: [runtime, makeSecondRuntime()],
            archiveStore: store
        )
        await service.refreshCapabilities()
        try service.selectProvider(ProviderID("beta"))
        await service.saveNow()

        let relaunched = AgentSessionService(runtimes: [runtime], archiveStore: store)

        XCTAssertEqual(relaunched.sessions.count, 1)
        XCTAssertEqual(relaunched.state.configuration?.providerID, ProviderID("beta"))
    }

    func testActivityTimelineSurvivesARelaunch() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let activityID = ProviderActivityID("tool-1")
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
        let service = AgentSessionService(runtimes: [runtime], archiveStore: store)
        await service.refreshCapabilities()

        let turn = try XCTUnwrap(service.submit("Run the tests"))
        pair.continuation.yield(
            .activityStarted(
                ProviderActivityDescriptor(
                    id: activityID,
                    kind: .command,
                    title: "Running swift test",
                    detail: "swift test",
                    output: nil
                )
            )
        )
        pair.continuation.yield(
            .activityFinished(
                activityID,
                outcome: .completed,
                output: "All tests passed",
                diff: "+ one line"
            )
        )
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value

        let promptID = try XCTUnwrap(service.state.messages.first?.id)
        await service.saveNow()

        let relaunched = AgentSessionService(runtimes: [runtime], archiveStore: store)
        let activity = try XCTUnwrap(
            relaunched.state.activityGroups
                .flatMap(\.activities)
                .first { $0.id == activityID },
            "The commands a turn ran have to outlive the process like the messages do"
        )

        XCTAssertEqual(relaunched.state.activityGroups.first?.anchorMessageID, promptID)
        XCTAssertEqual(activity.kind, .command)
        XCTAssertEqual(activity.title, "Running swift test")
        XCTAssertEqual(activity.output, "All tests passed")
        XCTAssertEqual(activity.diff, "+ one line")
        XCTAssertEqual(activity.phase, .completed)
        XCTAssertNotNil(activity.completedAt)
    }

    func testActivityThatWasRunningWhenTheAppQuitIsClosedOnRestore() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = SessionSnapshot(
            id: UUID(),
            createdAt: startedAt,
            configuration: nil,
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "Keep going",
                    attachmentPaths: [],
                    createdAt: startedAt
                )
            ],
            activityGroups: [
                AgentTurnActivityGroup(
                    id: UUID(),
                    anchorMessageID: UUID(),
                    activities: [
                        AgentActivity(
                            id: ProviderActivityID("thinking"),
                            kind: .thinking,
                            phase: .running,
                            title: nil,
                            detail: nil,
                            output: nil,
                            startedAt: startedAt,
                            completedAt: nil
                        )
                    ]
                )
            ]
        )

        let session = AgentSession(runtimes: [makeRuntime()], snapshot: snapshot)
        let activity = try XCTUnwrap(session.state.activityGroups.first?.activities.first)

        XCTAssertEqual(
            activity.phase,
            .cancelled,
            "A turn cannot still be running after the app was restarted"
        )
        XCTAssertEqual(
            activity.completedAt,
            startedAt,
            "The elapsed time has to stop when the app did"
        )
    }

    func testArchiveBoundsTheStoredActivityHistory() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let message = ChatMessage(role: .user, text: "Go")
        let longOutput = String(repeating: "x", count: SessionArchiveStore.maximumActivityOutputLength * 2)
        let snapshot = SessionSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            configuration: nil,
            messages: [message],
            activityGroups: [
                AgentTurnActivityGroup(
                    id: UUID(),
                    anchorMessageID: message.id,
                    activities: (0..<8).map { index in
                        AgentActivity(
                            id: ProviderActivityID("tool-\(index)"),
                            kind: .command,
                            phase: .completed,
                            title: "Running command \(index)",
                            detail: "command \(index)",
                            output: longOutput,
                            startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                            completedAt: Date(timeIntervalSince1970: TimeInterval(index))
                        )
                    }
                ),
                AgentTurnActivityGroup(
                    id: UUID(),
                    anchorMessageID: UUID(),
                    activities: [
                        AgentActivity(
                            id: ProviderActivityID("orphan"),
                            kind: .command,
                            phase: .completed,
                            title: "Orphaned",
                            detail: nil,
                            output: nil,
                            startedAt: Date(),
                            completedAt: Date()
                        )
                    ]
                )
            ]
        )

        await store.save(
            SessionArchive(
                version: SessionArchive.currentVersion,
                activeSessionID: snapshot.id,
                sessions: [snapshot]
            )
        )

        let loaded = try XCTUnwrap(store.load())
        let groups = try XCTUnwrap(loaded.sessions.first?.activityGroups)

        XCTAssertEqual(groups.count, 1, "A timeline with no message left has nothing to hang under")

        let activities = groups.flatMap(\.activities)
        XCTAssertEqual(activities.count, 8)

        for activity in activities {
            let output = try XCTUnwrap(activity.output)
            XCTAssertLessThanOrEqual(
                output.count,
                SessionArchiveStore.maximumActivityOutputLength + 80,
                "A huge tool result would push the archive past the size it is allowed to be"
            )
            XCTAssertTrue(output.contains("more characters were not stored"))
        }
    }

    func testASingleTurnLongerThanTheBudgetKeepsItsNewestSteps() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let message = ChatMessage(role: .user, text: "Work through this")
        let activityCount = SessionArchiveStore.maximumActivitiesPerSession + 5
        let snapshot = SessionSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            configuration: nil,
            messages: [message],
            activityGroups: [
                AgentTurnActivityGroup(
                    id: UUID(),
                    anchorMessageID: message.id,
                    activities: (0..<activityCount).map { index in
                        AgentActivity(
                            id: ProviderActivityID("step-\(index)"),
                            kind: .read,
                            phase: .completed,
                            title: "Read file \(index)",
                            detail: "file-\(index).swift",
                            output: nil,
                            startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                            completedAt: Date(timeIntervalSince1970: TimeInterval(index))
                        )
                    }
                )
            ]
        )

        await store.save(
            SessionArchive(
                version: SessionArchive.currentVersion,
                activeSessionID: snapshot.id,
                sessions: [snapshot]
            )
        )

        let loaded = try XCTUnwrap(store.load())
        let activities = try XCTUnwrap(loaded.sessions.first?.activityGroups).flatMap(\.activities)

        XCTAssertEqual(activities.count, SessionArchiveStore.maximumActivitiesPerSession)
        XCTAssertEqual(
            activities.last?.id,
            ProviderActivityID("step-\(activityCount - 1)"),
            "The newest steps are the ones kept"
        )
    }

    func testArchiveFromBeforeTheActivityTimelineStillDecodes() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID()
        let legacyJSON = """
        {
          "version": 1,
          "activeSessionID": "\(sessionID.uuidString)",
          "sessions": [
            {
              "id": "\(sessionID.uuidString)",
              "createdAt": "2023-11-14T22:13:20Z",
              "messages": [
                {
                  "id": "\(UUID().uuidString)",
                  "role": "user",
                  "text": "hello",
                  "attachmentPaths": [],
                  "createdAt": "2023-11-14T22:13:20Z"
                }
              ]
            }
          ]
        }
        """

        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacyJSON.utf8).write(to: store.fileURL)

        let archive = try XCTUnwrap(store.load())
        XCTAssertEqual(archive.sessions.count, 1)
        XCTAssertEqual(archive.sessions.first?.messages.map(\.text), ["hello"])
        XCTAssertEqual(
            archive.sessions.first?.activityGroups,
            [],
            "An archive written before the timeline existed simply has none"
        )
    }

    func testArchiveStoreRoundTripsThroughJSON() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = SessionSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            configuration: SessionConfiguration(
                providerID: ProviderID("openai"),
                modelID: ProviderModelID("gpt-5.6"),
                variantID: ProviderVariantID("high")
            ),
            // Dates are stored with second precision, which is all a transcript
            // needs and keeps the archive readable.
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "hello",
                    attachmentPaths: ["/tmp/a.png"],
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    text: "hi",
                    attachmentPaths: [],
                    createdAt: Date(timeIntervalSince1970: 1_700_000_200)
                )
            ]
        )
        let archive = SessionArchive(
            version: SessionArchive.currentVersion,
            activeSessionID: snapshot.id,
            sessions: [snapshot]
        )

        await store.save(archive)

        XCTAssertEqual(store.load(), archive)
    }

    func testCorruptArchiveIsKeptAsideInsteadOfBeingOverwritten() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json at all".utf8).write(to: store.fileURL)

        XCTAssertNil(store.load())

        let aside = store.fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testArchiveFromANewerVersionIsIgnored() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = SessionArchive(
            version: SessionArchive.currentVersion + 1,
            activeSessionID: UUID(),
            sessions: []
        )
        await store.save(archive)

        XCTAssertNil(store.load())
    }

    func testArchiveKeepsOnlyTheMostRecentSessions() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshots = (0..<(SessionArchiveStore.maximumSessionCount + 10)).map { index in
            SessionSnapshot(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                configuration: nil,
                messages: [ChatMessage(role: .user, text: "message \(index)")]
            )
        }
        let newestID = snapshots.last!.id

        await store.save(
            SessionArchive(
                version: SessionArchive.currentVersion,
                activeSessionID: newestID,
                sessions: snapshots
            )
        )

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.sessions.count, SessionArchiveStore.maximumSessionCount)
        XCTAssertTrue(
            loaded.sessions.contains { $0.id == newestID },
            "The newest conversations are the ones worth keeping"
        )
        XCTAssertEqual(loaded.activeSessionID, newestID)
    }

    func testMissingArchiveStartsWithOneEmptySession() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = AgentSessionService(runtimes: [makeRuntime()], archiveStore: store)

        XCTAssertEqual(service.sessions.count, 1)
        XCTAssertTrue(service.state.messages.isEmpty)
        XCTAssertEqual(service.activeSessionTitle, "New session")
    }

    func testAnArchiveOverTheCeilingIsKeptAsideInsteadOfBeingOverwritten() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Seyrek dosya: 64 MB'ı gerçekten yazmadan tavanın üstüne çıkar.
        XCTAssertTrue(
            FileManager.default.createFile(atPath: store.fileURL.path, contents: Data())
        )
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.truncate(atOffset: UInt64(SessionArchiveStore.maximumArchiveBytes + 1))
        try handle.close()

        XCTAssertNil(store.load())

        let aside = store.fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: aside.path),
            "Refusing to read an archive must not leave it to be destroyed by the next write"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testAnOversizedArchiveDropsTheOldestInactiveConversationFirst() throws {
        let active = makeSnapshot(text: "active", createdAt: 300)
        let middle = makeSnapshot(text: "middle", createdAt: 200)
        let oldest = makeSnapshot(text: "oldest", createdAt: 100)
        let archive = SessionArchive(
            version: SessionArchive.currentVersion,
            activeSessionID: active.id,
            sessions: [active, middle, oldest]
        )

        let reduced = try XCTUnwrap(archive.droppingOldestStoredContent())

        XCTAssertEqual(
            reduced.sessions.map(\.id),
            [active.id, middle.id],
            "The conversation being read is the last one to go"
        )
    }

    func testTheLastConversationLosesItsOldestMessagesBeforeItIsLost() throws {
        var session = makeSnapshot(text: "message 0", createdAt: 100)
        session.messages = (0..<20).map { ChatMessage(role: .user, text: "message \($0)") }
        session.activityGroups = [
            AgentTurnActivityGroup(
                id: UUID(),
                anchorMessageID: session.messages[0].id,
                activities: []
            ),
            AgentTurnActivityGroup(
                id: UUID(),
                anchorMessageID: session.messages[19].id,
                activities: []
            )
        ]

        let archive = SessionArchive(
            version: SessionArchive.currentVersion,
            activeSessionID: session.id,
            sessions: [session]
        )

        let reduced = try XCTUnwrap(archive.droppingOldestStoredContent())
        let remaining = try XCTUnwrap(reduced.sessions.first)

        XCTAssertEqual(remaining.messages.count, 18)
        XCTAssertEqual(remaining.messages.first?.text, "message 2")
        XCTAssertEqual(
            remaining.activityGroups.count,
            1,
            "A timeline whose message is gone has nothing left to hang under"
        )
    }

    func testAConversationWithASingleMessageCannotShrinkAnyFurther() throws {
        let session = makeSnapshot(text: "only", createdAt: 100)
        let archive = SessionArchive(
            version: SessionArchive.currentVersion,
            activeSessionID: session.id,
            sessions: [session]
        )

        XCTAssertNil(
            archive.droppingOldestStoredContent(),
            "There has to be a point where the archive refuses to write instead of storing nothing"
        )
    }

    func testTheWriterShrinksAnOversizedArchiveUntilItFitsAndWritesIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sessions.json")

        let active = makeSnapshot(text: String(repeating: "a", count: 400), createdAt: 300)
        let older = (0..<6).map {
            makeSnapshot(text: String(repeating: "b", count: 400), createdAt: TimeInterval($0))
        }
        let archive = SessionArchive(
            version: SessionArchive.currentVersion,
            activeSessionID: active.id,
            sessions: older + [active]
        )

        let writer = SessionArchiveWriter(fileURL: fileURL)
        await writer.write(
            archive,
            bounds: SessionArchiveBounds(
                maximumSessionCount: 50,
                maximumActivities: 120,
                maximumOutputLength: 4_000,
                maximumBytes: 2_000
            )
        )

        let data = try XCTUnwrap(FileManager.default.contents(atPath: fileURL.path))
        XCTAssertLessThanOrEqual(
            data.count,
            2_000,
            "The ceiling has to hold at the moment of writing, not be discovered on the next launch"
        )

        let store = SessionArchiveStore(fileURL: fileURL)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertLessThan(loaded.sessions.count, archive.sessions.count)
        XCTAssertTrue(
            loaded.sessions.contains { $0.id == active.id },
            "The conversation being read is the last one to be dropped"
        )
    }

    func testTheWriterKeepsThePreviousArchiveWhenNothingCanFit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sessions.json")

        let writer = SessionArchiveWriter(fileURL: fileURL)
        await writer.write(
            SessionArchive(
                version: SessionArchive.currentVersion,
                activeSessionID: UUID(),
                sessions: [makeSnapshot(text: "only", createdAt: 1)]
            ),
            bounds: SessionArchiveBounds(
                maximumSessionCount: 50,
                maximumActivities: 120,
                maximumOutputLength: 4_000,
                maximumBytes: 10
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "Writing nothing at all is worse than keeping what was already stored"
        )
    }

    private func makeSnapshot(text: String, createdAt: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: createdAt),
            configuration: nil,
            messages: [ChatMessage(role: .user, text: text)]
        )
    }

    private func makeStore() throws -> (SessionArchiveStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-archive-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return (
            SessionArchiveStore(fileURL: directory.appendingPathComponent("sessions.json")),
            directory
        )
    }

    private func makeRuntime() -> TestProviderRuntime {
        TestProviderRuntime(
            id: ProviderID("alpha"),
            displayName: "Alpha",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("alpha-1"),
                    displayName: "Alpha 1",
                    variants: []
                )
            ]
        )
    }

    private func makeSecondRuntime() -> TestProviderRuntime {
        TestProviderRuntime(
            id: ProviderID("beta"),
            displayName: "Beta",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("beta-1"),
                    displayName: "Beta 1",
                    variants: []
                )
            ]
        )
    }
}

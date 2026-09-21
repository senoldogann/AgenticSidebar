import Foundation
import XCTest

@testable import AgenticSidebar

final class FileChangesModelTests: XCTestCase {
    func testSingleFileEditDiffCounts() {
        let diff = """
            - old line 1
            - old line 2
            + new line 1
            + new line 2
            + new line 3
            """

        let activity = AgentActivity(
            id: ProviderActivityID("act-1"),
            kind: .edit,
            phase: .completed,
            title: "Edited Main.swift",
            detail: "/workspace/Sources/Main.swift",
            output: "Success",
            diff: diff,
            startedAt: Date(),
            completedAt: Date()
        )

        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [activity]
        )

        let summary = TurnFileChangesSummary.from(group: group)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.totalAdditions, 3)
        XCTAssertEqual(summary.totalDeletions, 2)

        let item = summary.files.first
        XCTAssertEqual(item?.fileName, "Main.swift")
        XCTAssertEqual(item?.additions, 3)
        XCTAssertEqual(item?.deletions, 2)
        XCTAssertFalse(item?.isNewFile ?? true)
    }

    func testMultipleEditsToSameFileAreConsolidated() {
        let diff1 = """
            - line A
            + line B
            """
        let diff2 = """
            + line C
            + line D
            """

        let act1 = AgentActivity(
            id: ProviderActivityID("act-1"),
            kind: .edit,
            phase: .completed,
            title: "Edited App.swift",
            detail: "/workspace/Sources/App.swift",
            output: "Success",
            diff: diff1,
            startedAt: Date(),
            completedAt: Date()
        )
        let act2 = AgentActivity(
            id: ProviderActivityID("act-2"),
            kind: .edit,
            phase: .completed,
            title: "Edited App.swift",
            detail: "/workspace/Sources/App.swift",
            output: "Success",
            diff: diff2,
            startedAt: Date(),
            completedAt: Date()
        )

        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [act1, act2]
        )

        let summary = TurnFileChangesSummary.from(group: group)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.totalAdditions, 3)
        XCTAssertEqual(summary.totalDeletions, 1)

        let item = summary.files.first
        XCTAssertEqual(item?.fileName, "App.swift")
        XCTAssertEqual(item?.additions, 3)
        XCTAssertEqual(item?.deletions, 1)
    }

    func testMultipleDistinctFilesAndNewFiles() {
        let diffApp = "- let x = 1\n+ let x = 2"
        let diffNormalizer = "+ let y = 10\n+ let z = 20"

        let act1 = AgentActivity(
            id: ProviderActivityID("act-1"),
            kind: .edit,
            phase: .completed,
            title: "Edited App.swift",
            detail: "/workspace/Sources/App.swift",
            output: "Done",
            diff: diffApp,
            startedAt: Date(),
            completedAt: Date()
        )
        let act2 = AgentActivity(
            id: ProviderActivityID("act-2"),
            kind: .update,
            phase: .completed,
            title: "Created Normalizer.swift",
            detail: "/workspace/Sources/Normalizer.swift",
            output: "Done",
            diff: diffNormalizer,
            startedAt: Date(),
            completedAt: Date()
        )

        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [act1, act2]
        )

        let summary = TurnFileChangesSummary.from(group: group)
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.totalAdditions, 3)
        XCTAssertEqual(summary.totalDeletions, 1)

        XCTAssertEqual(summary.files[0].fileName, "App.swift")
        XCTAssertFalse(summary.files[0].isNewFile)
        XCTAssertEqual(summary.files[1].fileName, "Normalizer.swift")
        XCTAssertTrue(summary.files[1].isNewFile)
    }

    func testNonFileActivitiesAreIgnored() {
        let commandAct = AgentActivity(
            id: ProviderActivityID("act-cmd"),
            kind: .command,
            phase: .completed,
            title: "Ran swift test",
            detail: "swift test",
            output: "Passed",
            diff: nil,
            startedAt: Date(),
            completedAt: Date()
        )

        let thinkingAct = AgentActivity(
            id: ProviderActivityID("act-think"),
            kind: .thinking,
            phase: .completed,
            title: "Thinking",
            detail: nil,
            output: "Thoughts",
            diff: nil,
            startedAt: Date(),
            completedAt: Date()
        )

        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [commandAct, thinkingAct]
        )

        let summary = TurnFileChangesSummary.from(group: group)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.fileCount, 0)
    }

    func testDeterministicFileChangeItemIDsAcrossInvocations() {
        let diff = "+ let answer = 42\n"
        let act = AgentActivity(
            id: ProviderActivityID("act-edit"),
            kind: .edit,
            phase: .completed,
            title: "Edited File.swift",
            detail: "/workspace/File.swift",
            output: "Done",
            diff: diff,
            startedAt: Date(),
            completedAt: Date()
        )

        let fixedGroupID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let group = AgentTurnActivityGroup(
            id: fixedGroupID,
            anchorMessageID: UUID(),
            activities: [act]
        )

        let summary1 = TurnFileChangesSummary.from(group: group)
        let summary2 = TurnFileChangesSummary.from(group: group)

        XCTAssertEqual(summary1.files.count, 1)
        XCTAssertEqual(summary2.files.count, 1)
        XCTAssertEqual(summary1.files.first?.id, summary2.files.first?.id)
        XCTAssertEqual(summary1, summary2)
    }

    /// Oturum sonu kartı: gruplar yola göre birleşir, sayılar toplanır, sıra
    /// ilk görünüm sırasıdır.
    func testMergedSummaryAcrossGroups() {
        func editAct(id: String, detail: String, diff: String) -> AgentActivity {
            AgentActivity(
                id: ProviderActivityID(id),
                kind: .edit,
                phase: .completed,
                title: "Edited file",
                detail: detail,
                output: "Done",
                diff: diff,
                startedAt: Date(),
                completedAt: Date()
            )
        }

        let group1 = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [editAct(id: "a1", detail: "/workspace/A.swift", diff: "+ one\n- old")]
        )
        let group2 = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [
                editAct(id: "a2", detail: "/workspace/A.swift", diff: "+ two"),
                editAct(id: "a3", detail: "/workspace/B.swift", diff: "+ bee"),
            ]
        )

        let merged = TurnFileChangesSummary.merged(from: [group1, group2])
        XCTAssertEqual(merged.fileCount, 2)
        XCTAssertEqual(merged.files.map(\.fileName), ["A.swift", "B.swift"])
        XCTAssertEqual(merged.totalAdditions, 3)
        XCTAssertEqual(merged.totalDeletions, 1)
        XCTAssertTrue(TurnFileChangesSummary.merged(from: []).isEmpty)
    }

    func testDiffHeadersAreNotCountedAsChanges() {
        let diff = """
            --- a/Main.swift
            +++ b/Main.swift
            - old
            + new
            """
        let activity = AgentActivity(
            id: ProviderActivityID("act-header"),
            kind: .edit,
            phase: .completed,
            title: "Edited Main.swift",
            detail: "/workspace/Sources/Main.swift",
            output: "Success",
            diff: diff,
            startedAt: Date(),
            completedAt: Date()
        )
        let group = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [activity]
        )
        let summary = TurnFileChangesSummary.from(group: group)
        XCTAssertEqual(summary.totalAdditions, 1)
        XCTAssertEqual(summary.totalDeletions, 1)
    }

    func testSessionReviewSummaryMergesAnyChangedTurns() {
        func editAct(id: String, detail: String, diff: String) -> AgentActivity {
            AgentActivity(
                id: ProviderActivityID(id),
                kind: .edit,
                phase: .completed,
                title: "Edited file",
                detail: detail,
                output: "Done",
                diff: diff,
                startedAt: Date(),
                completedAt: Date()
            )
        }
        func commandGroup() -> AgentTurnActivityGroup {
            AgentTurnActivityGroup(
                id: UUID(),
                anchorMessageID: UUID(),
                activities: [
                    AgentActivity(
                        id: ProviderActivityID(UUID().uuidString),
                        kind: .command,
                        phase: .completed,
                        title: "Running ls",
                        detail: "ls",
                        output: "ok",
                        diff: nil,
                        startedAt: Date(),
                        completedAt: Date()
                    )
                ]
            )
        }
        XCTAssertNil(TurnFileChangesSummary.sessionReviewSummary(from: []))
        XCTAssertNil(TurnFileChangesSummary.sessionReviewSummary(from: [commandGroup()]))
        let single = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [editAct(id: "s1", detail: "/workspace/A.swift", diff: "+ one")]
        )
        // Tek turun özeti de oturum bitince alta taşınır; satır içi kart gizlenir.
        let singleSummary = TurnFileChangesSummary.sessionReviewSummary(from: [single, commandGroup()])
        XCTAssertEqual(singleSummary?.fileCount, 1)
        XCTAssertEqual(singleSummary?.files.map(\.fileName), ["A.swift"])
        let second = AgentTurnActivityGroup(
            id: UUID(),
            anchorMessageID: UUID(),
            activities: [editAct(id: "s2", detail: "/workspace/B.swift", diff: "+ two")]
        )
        let merged = TurnFileChangesSummary.sessionReviewSummary(from: [single, commandGroup(), second])
        XCTAssertEqual(merged?.fileCount, 2)
        XCTAssertEqual(merged?.files.map(\.fileName), ["A.swift", "B.swift"])
    }
}

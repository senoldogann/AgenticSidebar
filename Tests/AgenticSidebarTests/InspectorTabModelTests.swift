import Foundation
import XCTest
@testable import AgenticSidebar

final class InspectorTabModelTests: XCTestCase {
    func testForFileCreatesValidTab() {
        let fileURL = URL(fileURLWithPath: "/workspace/Sources/App.swift")
        let tab = InspectorTab.forFile(url: fileURL)

        XCTAssertEqual(tab.title, "App.swift")
        XCTAssertEqual(tab.iconName, "swift")
        XCTAssertEqual(tab.iconColorName, "orange")
        XCTAssertEqual(tab.id, "file:/workspace/Sources/App.swift")

        if case let .file(url) = tab.kind {
            XCTAssertEqual(url.lastPathComponent, "App.swift")
        } else {
            XCTFail("Expected file tab kind")
        }
    }

    func testForSubagentReportCreatesValidTab() {
        let activity = AgentActivity(
            id: ProviderActivityID("task-123"),
            kind: .subagent,
            phase: .completed,
            title: "Code Review Subagent",
            detail: "Analyzed changes",
            output: "All clear",
            startedAt: Date(),
            completedAt: Date()
        )

        let tab = InspectorTab.forSubagentReport(activity: activity)
        XCTAssertEqual(tab.title, "Code Review Subagent")
        XCTAssertEqual(tab.iconName, "arrow.triangle.branch")
        XCTAssertEqual(tab.id, "report:task-123")

        if case let .subagentReport(actID, title, report) = tab.kind {
            XCTAssertEqual(actID.rawValue, "task-123")
            XCTAssertEqual(title, "Code Review Subagent")
            XCTAssertEqual(report, "All clear")
        } else {
            XCTFail("Expected subagentReport tab kind")
        }
    }

    func testForReviewCreatesValidTab() {
        let item = FileChangeItem(
            id: UUID(),
            path: "/workspace/File.swift",
            additions: 5,
            deletions: 2,
            isNewFile: false,
            diff: "+ new\n- old"
        )
        let turnID = UUID()
        let summary = TurnFileChangesSummary(id: turnID, files: [item])

        let tab = InspectorTab.forReview(summary: summary, initialFile: item)
        XCTAssertEqual(tab.title, "Changes (1)")
        XCTAssertEqual(tab.iconName, "doc.badge.plus")
        XCTAssertEqual(tab.id, "review:\(turnID.uuidString)")

        if case let .changesReview(tid, sum, initFile) = tab.kind {
            XCTAssertEqual(tid, turnID)
            XCTAssertEqual(sum.fileCount, 1)
            XCTAssertEqual(initFile?.fileName, "File.swift")
        } else {
            XCTFail("Expected changesReview tab kind")
        }
    }

    func testTabIDsAreConsistentForSamePath() {
        let url1 = URL(fileURLWithPath: "/workspace/App.swift")
        let url2 = URL(fileURLWithPath: "/workspace/App.swift")
        let tab1 = InspectorTab.forFile(url: url1)
        let tab2 = InspectorTab.forFile(url: url2)

        XCTAssertEqual(tab1.id, tab2.id)
    }

    func testDisplayLabelNumbering() {
        let file1 = InspectorTab.forFile(url: URL(fileURLWithPath: "/workspace/App.swift"))
        let file2 = InspectorTab.forFile(url: URL(fileURLWithPath: "/workspace/Models.swift"))

        let agentActivity1 = AgentActivity(
            id: ProviderActivityID("agent-1"),
            kind: .subagent,
            phase: .completed,
            title: "Subagent 1",
            detail: nil,
            output: "Result 1",
            startedAt: Date(),
            completedAt: Date()
        )
        let agent1 = InspectorTab.forSubagentReport(activity: agentActivity1)

        let agentActivity2 = AgentActivity(
            id: ProviderActivityID("agent-2"),
            kind: .subagent,
            phase: .completed,
            title: "Subagent 2",
            detail: nil,
            output: "Result 2",
            startedAt: Date(),
            completedAt: Date()
        )
        let agent2 = InspectorTab.forSubagentReport(activity: agentActivity2)

        let allTabs = [file1, agent1, file2, agent2]

        XCTAssertEqual(InspectorTab.displayLabel(for: file1, among: allTabs), "Sekme 1")
        XCTAssertEqual(InspectorTab.displayLabel(for: file2, among: allTabs), "Sekme 2")
        XCTAssertEqual(InspectorTab.displayLabel(for: agent1, among: allTabs), "Agent 1")
        XCTAssertEqual(InspectorTab.displayLabel(for: agent2, among: allTabs), "Agent 2")
    }
}

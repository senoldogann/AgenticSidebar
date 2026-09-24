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

        if case .file(let url) = tab.kind {
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

        if case .subagentReport(let actID, let title, let report) = tab.kind {
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

        if case .changesReview(let tid, let sum, let initFile) = tab.kind {
            XCTAssertEqual(tid, turnID)
            XCTAssertEqual(sum.fileCount, 1)
            XCTAssertEqual(initFile?.fileName, "File.swift")
        } else {
            XCTFail("Expected changesReview tab kind")
        }
    }

    func testForSessionChangesKeepsStableTabID() {
        let item = FileChangeItem(
            id: UUID(),
            path: "/workspace/File.swift",
            additions: 5,
            deletions: 2,
            isNewFile: false,
            diff: "+ new\n- old"
        )
        let sessionID = UUID()
        let first = TurnFileChangesSummary(id: UUID(), files: [item])
        let second = TurnFileChangesSummary(id: UUID(), files: [item, item])

        let firstTab = InspectorTab.forSessionChanges(sessionID: sessionID, summary: first)
        let secondTab = InspectorTab.forSessionChanges(sessionID: sessionID, summary: second)

        // Canlı tazeleme aynı sekmeyi günceller, sekme çoğaltmaz.
        XCTAssertEqual(firstTab.id, "session-changes:\(sessionID.uuidString)")
        XCTAssertEqual(secondTab.id, firstTab.id)
        XCTAssertEqual(firstTab.title, "Changes (1)")
        XCTAssertEqual(secondTab.title, "Changes (2)")
    }

    func testPanelTabFactoriesCreatePerPaneTabs() {
        let browser = InspectorTab.forBrowser(paneID: "secondary")
        XCTAssertEqual(browser.id, "browser:secondary")
        XCTAssertEqual(browser.kind, .browser)
        XCTAssertEqual(browser.title, "Browser")
        XCTAssertEqual(browser.iconName, "globe")

        let simulator = InspectorTab.forSimulator(paneID: "secondary")
        XCTAssertEqual(simulator.id, "simulator:secondary")
        XCTAssertEqual(simulator.kind, .simulator)
        XCTAssertEqual(simulator.title, "Simulator")
        XCTAssertEqual(simulator.iconName, "iphone")

        let computer = InspectorTab.forComputerLive(paneID: "secondary")
        XCTAssertEqual(computer.id, "computer:secondary")
        XCTAssertEqual(computer.kind, .computerLive)
        XCTAssertEqual(computer.title, "Computer")
        XCTAssertEqual(computer.iconName, "computermouse")
    }

    /// Panel sekmeleri ajan sekmeleriyle karışmaz: numaralandırma "Sekme N"
    /// üzerinden yürür.
    func testPanelTabsUseNumberedLabels() {
        let terminal = InspectorTab.forTerminal(paneID: "primary", workingDirectory: "/tmp")
        let browser = InspectorTab.forBrowser(paneID: "primary")
        let simulator = InspectorTab.forSimulator(paneID: "primary")
        let computer = InspectorTab.forComputerLive(paneID: "primary")
        let allTabs = [terminal, browser, simulator, computer]

        XCTAssertEqual(InspectorTab.displayLabel(for: terminal, among: allTabs), "Sekme 1")
        XCTAssertEqual(InspectorTab.displayLabel(for: browser, among: allTabs), "Sekme 2")
        XCTAssertEqual(InspectorTab.displayLabel(for: simulator, among: allTabs), "Sekme 3")
        XCTAssertEqual(InspectorTab.displayLabel(for: computer, among: allTabs), "Sekme 4")
    }

    func testTerminalTabIDIncludesDirectory() {
        let first = InspectorTab.forTerminal(paneID: "primary", workingDirectory: "/repo/a")
        let same = InspectorTab.forTerminal(paneID: "primary", workingDirectory: "/repo/a")
        let otherDir = InspectorTab.forTerminal(paneID: "primary", workingDirectory: "/repo/b")
        let otherPane = InspectorTab.forTerminal(paneID: "secondary", workingDirectory: "/repo/a")

        // Aynı klasör aynı sekmeyi verir (canlı kabuk korunur), başka
        // klasör ya da bölme yeni sekme açar.
        XCTAssertEqual(first.id, same.id)
        XCTAssertNotEqual(first.id, otherDir.id)
        XCTAssertNotEqual(first.id, otherPane.id)
        if case .terminal(let id, _) = first.kind {
            XCTAssertEqual(id, first.id)
        } else {
            XCTFail("Expected terminal tab kind")
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

    // MARK: - Oturum başına panel durumu

    /// Sohbet değişiminde çıkanın sekmeleri saklanır, gelen boş panel alır:
    /// bir sohbette açılan rapor diğer sohbete sızmaz.
    func testInspectorStateSwitchSavesOutgoingAndRestoresEmpty() {
        let first = UUID()
        let second = UUID()
        let tab = InspectorTab.forFile(url: URL(fileURLWithPath: "/workspace/App.swift"))
        let current = InspectorPaneState(tabs: [tab], selectedID: tab.id, expanded: true)

        let result = InspectorPaneState.switched(
            [:],
            from: first,
            to: second,
            current: current,
            liveIDs: [first, second]
        )

        XCTAssertEqual(result.states[first]?.tabs, [tab])
        XCTAssertEqual(result.states[first]?.selectedID, tab.id)
        XCTAssertEqual(result.states[first]?.expanded, true)
        XCTAssertEqual(result.restored, InspectorPaneState())
    }

    /// Geri dönünce kayıtlı sekmeler aynen geri gelir (seçim ve genişletme dahil).
    func testInspectorStateSwitchRoundTrip() {
        let first = UUID()
        let second = UUID()
        let tab = InspectorTab.forFile(url: URL(fileURLWithPath: "/workspace/App.swift"))
        let saved = InspectorPaneState(tabs: [tab], selectedID: tab.id, expanded: true)

        let away = InspectorPaneState.switched(
            [first: saved],
            from: second,
            to: first,
            current: InspectorPaneState(),
            liveIDs: [first, second]
        )
        XCTAssertEqual(away.restored, saved)

        let back = InspectorPaneState.switched(
            away.states,
            from: first,
            to: second,
            current: away.restored,
            liveIDs: [first, second]
        )
        XCTAssertEqual(back.restored, InspectorPaneState())
        XCTAssertEqual(back.states[first], saved)
    }

    /// Silinmiş sohbetlerin kayıtları tutulmaz.
    func testInspectorStateSwitchDropsDeadSessions() {
        let live = UUID()
        let dead = UUID()
        let tab = InspectorTab.forFile(url: URL(fileURLWithPath: "/workspace/App.swift"))

        let result = InspectorPaneState.switched(
            [dead: InspectorPaneState(tabs: [tab], selectedID: tab.id, expanded: false)],
            from: dead,
            to: live,
            current: InspectorPaneState(),
            liveIDs: [live]
        )

        XCTAssertNil(result.states[dead])
        XCTAssertEqual(result.restored, InspectorPaneState())
    }

    /// Aynı oturumda değişim yok: sözlük ve mevcut durum aynen döner.
    func testInspectorStateSwitchSameSessionIsNoOp() {
        let only = UUID()
        let tab = InspectorTab.forFile(url: URL(fileURLWithPath: "/workspace/App.swift"))
        let current = InspectorPaneState(tabs: [tab], selectedID: tab.id, expanded: false)

        let result = InspectorPaneState.switched(
            [:],
            from: only,
            to: only,
            current: current,
            liveIDs: [only]
        )

        XCTAssertTrue(result.states.isEmpty)
        XCTAssertEqual(result.restored, current)
    }
}

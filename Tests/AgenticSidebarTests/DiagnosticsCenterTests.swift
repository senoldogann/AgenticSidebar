import Foundation
import XCTest

@testable import AgenticSidebar

/// Tanı merkezi: anlık görüntü toplama, dışa aktarma ve çalışma süresi.
///
/// Çıta: boş dizinde boş anlık görüntü döner, dışa aktarma tüm bölümleri
/// taşır, çalışma süresi İngilizce kısaltmalarla biçimlenir.
final class DiagnosticsCenterTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testCollectOnEmptyDirectoryReturnsEmptySnapshot() async {
        let directory = temporaryDirectory()
        let audit = ToolAuditLog(
            fileURL: directory.appendingPathComponent("audit.jsonl")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = await DiagnosticsCenter.collect(
            auditLog: audit,
            crashesDirectory: directory
        )

        XCTAssertFalse(snapshot.appVersion.isEmpty)
        XCTAssertFalse(snapshot.previousRunCrashed)
        XCTAssertTrue(snapshot.crashReports.isEmpty)
        XCTAssertTrue(snapshot.recentDecisions.isEmpty)
        XCTAssertTrue(snapshot.recentExecutions.isEmpty)
    }

    func testExportMarkdownCarriesAllSections() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "1.0 (1)",
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            collectedAt: Date(timeIntervalSince1970: 1_700_003_600),
            previousRunCrashed: true,
            crashReports: [],
            recentDecisions: [],
            recentExecutions: []
        )

        let text = DiagnosticsCenter.exportMarkdown(snapshot)

        XCTAssertTrue(text.contains("1.0 (1)"))
        XCTAssertTrue(text.contains("## Crash Reports"))
        XCTAssertTrue(text.contains("## Recent Tool Decisions"))
        XCTAssertTrue(text.contains("## Recent Tool Executions"))
        XCTAssertTrue(text.contains("yes"))
    }

    func testUptimeStringFormatsEnglishShortUnits() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            DiagnosticsCenter.uptimeString(from: start, to: start.addingTimeInterval(30)),
            "30 sec"
        )
        XCTAssertEqual(
            DiagnosticsCenter.uptimeString(from: start, to: start.addingTimeInterval(150)),
            "2 min"
        )
        XCTAssertEqual(
            DiagnosticsCenter.uptimeString(from: start, to: start.addingTimeInterval(7_500)),
            "2 h 5 min"
        )
    }

    func testExportExtendsFenceWhenCrashTextContainsBackticks() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "1.0 (1)",
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            collectedAt: Date(timeIntervalSince1970: 1_700_003_600),
            previousRunCrashed: false,
            crashReports: [
                CrashReport(
                    name: "crash-20260918-000000-1.log",
                    url: URL(fileURLWithPath: "/tmp/olmayan.log"),
                    date: nil,
                    size: 3,
                    text: "önce ``` sonra"
                )
            ],
            recentDecisions: [],
            recentExecutions: []
        )

        let text = DiagnosticsCenter.exportMarkdown(snapshot)

        XCTAssertTrue(text.contains("````\nönce ``` sonra\n````"))
        XCTAssertFalse(text.components(separatedBy: "\n").contains("```"))
    }

    func testFenceGrowsWithContent() {
        XCTAssertEqual(DiagnosticsCenter.fence(for: "düz metin"), "```")
        XCTAssertEqual(DiagnosticsCenter.fence(for: "içinde ``` var"), "````")
    }

    private func makeGoalFile(phase: GoalPhase, objective: String = "Pencereyi büyüt") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("goal-run.json")
        let run = GoalRun(
            id: UUID(),
            objective: objective,
            criteria: [],
            phase: phase,
            iteration: 2,
            startedAt: Date(timeIntervalSince1970: 2_000_000),
            toolCallCount: 7,
            log: [],
            failureReason: nil
        )
        let stored = GoalStoredRun(
            run: run,
            budget: GoalBudget(maxIterations: 5, maxDurationSeconds: 3_600, maxToolCalls: 300),
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectoryPath: "/tmp",
            updatedAt: Date(timeIntervalSince1970: 2_000_001)
        )
        try? GoalStore.save(stored, to: url)
        return url
    }

    func testCollectIncludesActiveGoalSummary() async {
        let goalURL = makeGoalFile(phase: .building)
        defer { try? FileManager.default.removeItem(at: goalURL.deletingLastPathComponent()) }
        let directory = temporaryDirectory()
        let audit = ToolAuditLog(
            fileURL: directory.appendingPathComponent("audit.jsonl")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = await DiagnosticsCenter.collect(
            auditLog: audit,
            crashesDirectory: directory,
            goalStoreURL: goalURL
        )

        let summary = snapshot.goalSummary
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("Pencereyi büyüt") ?? false)
        XCTAssertTrue(summary?.contains("building") ?? false)
    }

    func testCollectIgnoresTerminalGoalRun() async {
        let goalURL = makeGoalFile(phase: .done)
        defer { try? FileManager.default.removeItem(at: goalURL.deletingLastPathComponent()) }
        let directory = temporaryDirectory()
        let audit = ToolAuditLog(
            fileURL: directory.appendingPathComponent("audit.jsonl")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = await DiagnosticsCenter.collect(
            auditLog: audit,
            crashesDirectory: directory,
            goalStoreURL: goalURL
        )

        XCTAssertNil(snapshot.goalSummary)
    }

    func testExportCarriesGoalSection() {
        let active = DiagnosticsSnapshot(
            appVersion: "1.0 (1)",
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            collectedAt: Date(timeIntervalSince1970: 1_700_003_600),
            previousRunCrashed: false,
            crashReports: [],
            recentDecisions: [],
            recentExecutions: [],
            goalSummary: "“Pencereyi büyüt” · building · iteration 2/5"
        )
        XCTAssertTrue(DiagnosticsCenter.exportMarkdown(active).contains("## Goal Run"))
        XCTAssertTrue(DiagnosticsCenter.exportMarkdown(active).contains("Pencereyi büyüt"))

        let idle = DiagnosticsSnapshot(
            appVersion: "1.0 (1)",
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            collectedAt: Date(timeIntervalSince1970: 1_700_003_600),
            previousRunCrashed: false,
            crashReports: [],
            recentDecisions: [],
            recentExecutions: []
        )
        XCTAssertTrue(DiagnosticsCenter.exportMarkdown(idle).contains("## Goal Run"))
        XCTAssertNil(idle.goalSummary)
    }
}

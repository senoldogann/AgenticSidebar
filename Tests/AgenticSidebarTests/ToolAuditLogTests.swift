import Foundation
import XCTest

@testable import AgenticSidebar

final class ToolAuditLogTests: XCTestCase {
    func testRecordsAreReadBackOldestFirst() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = ToolAuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))

        await log.record(record(toolName: "bash", patterns: ["git status"], reply: .once))
        await log.record(record(toolName: "webfetch", patterns: ["https://example.com"], reply: .once))
        await log.record(record(toolName: "bash", patterns: ["rm -rf build"], reply: .reject))

        let recent = await log.recent(limit: 10)

        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.toolName), ["bash", "webfetch", "bash"])
        XCTAssertEqual(recent.map(\.reply), [.once, .once, .reject])
        XCTAssertEqual(recent.last?.patterns, ["rm -rf build"])
        XCTAssertEqual(recent.last?.source, .user)
    }

    func testExecutionEventsAreRecordedSeparatelyFromPermissionDecisions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ToolAuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))

        await log.recordExecution(
            ToolAuditLog.ExecutionRecord(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                sessionID: "ses_remote", activityID: "part-1", toolKind: .edit,
                title: "Edited source.swift", detail: "source.swift", event: .started
            ))
        await log.recordExecution(
            ToolAuditLog.ExecutionRecord(
                timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                sessionID: "ses_remote", activityID: "part-1", toolKind: .edit,
                title: "Edited source.swift", detail: "source.swift", event: .completed
            ))

        let executions = await log.recentExecutions(limit: 10)
        XCTAssertEqual(executions.map(\.event), [.started, .completed])
        XCTAssertEqual(executions.map(\.activityID), ["part-1", "part-1"])
        XCTAssertEqual(executions.first?.sessionID, "ses_remote")
        let decisions = await log.recent(limit: 10)
        XCTAssertTrue(decisions.isEmpty)
    }

    func testTheLimitKeepsTheNewestRecords() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = ToolAuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))

        for index in 0..<6 {
            await log.record(record(toolName: "tool-\(index)", patterns: [], reply: .once))
        }

        let recent = await log.recent(limit: 2)

        XCTAssertEqual(recent.map(\.toolName), ["tool-4", "tool-5"])
    }

    /// A partial final line is what an interrupted write leaves behind; the record
    /// before it is still valid, so the reader skips the fragment instead of
    /// failing the whole file.
    func testAPartialLineIsSkipped() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("audit.jsonl")
        let log = ToolAuditLog(fileURL: fileURL)

        await log.record(record(toolName: "bash", patterns: ["ls"], reply: .once))

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"2026-09-16T"#.utf8))
        try handle.close()

        let recent = await log.recent(limit: 10)

        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.toolName, "bash")
    }

    func testTheFileIsRotatedInsteadOfGrowingWithoutBound() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("audit.jsonl")
        let log = ToolAuditLog(fileURL: fileURL, maximumBytes: 400, maximumFiles: 3)

        for index in 0..<20 {
            await log.record(record(toolName: "tool-\(index)", patterns: [], reply: .once))
        }

        let rotated = directory.appendingPathComponent("audit.1.jsonl")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "The previous file is kept aside, not overwritten"
        )

        let size =
            (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        XCTAssertLessThan(size, 1_000)

        let recent = await log.recent(limit: 100)
        XCTAssertFalse(recent.isEmpty)
        XCTAssertEqual(recent.last?.toolName, "tool-19")
    }

    func testTheRecordCarriesTheDecisionAndItsReason() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = ToolAuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))

        await log.record(
            ToolAuditLog.Record(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                sessionID: "ses_remote",
                toolName: "bash",
                title: "Bash",
                detail: "command: git status",
                patterns: ["git status"],
                source: .policy,
                reply: .once
            )
        )

        let records = await log.recent(limit: 1)
        let decoded = try XCTUnwrap(records.first)

        XCTAssertEqual(decoded.sessionID, "ses_remote")
        XCTAssertEqual(decoded.title, "Bash")
        XCTAssertEqual(decoded.detail, "command: git status")
        XCTAssertEqual(decoded.source, .policy)
        XCTAssertEqual(decoded.source.label, "Level")
        XCTAssertEqual(decoded.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func record(
        toolName: String,
        patterns: [String],
        reply: ProviderPermissionReply
    ) -> ToolAuditLog.Record {
        ToolAuditLog.Record(
            timestamp: Date(),
            sessionID: "ses_1",
            toolName: toolName,
            title: toolName,
            detail: nil,
            patterns: patterns,
            source: .user,
            reply: reply
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticSidebarAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

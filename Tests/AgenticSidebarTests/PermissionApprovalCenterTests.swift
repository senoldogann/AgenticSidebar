import Foundation
import XCTest
@testable import AgenticSidebar

@MainActor
final class PermissionApprovalCenterTests: XCTestCase {
    func testSubmitSuspendsUntilResolved() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let request = makeRequest(id: "per_1", sessionID: "ses_1")

        let decision = Task { await center.submit(request) }
        await waitUntil { center.pending.count == 1 }

        let pending = center.pending.first
        XCTAssertEqual(pending?.id, "per_1")
        XCTAssertEqual(pending?.title, "Click")
        XCTAssertEqual(pending?.toolName, "chatgpt-system_computer_click")

        center.resolve(id: "per_1", reply: .once)

        let reply = await decision.value
        XCTAssertEqual(reply, .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testPendingPermissionPreservesOwningConversation() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil }, decisionTimeout: .seconds(60)
        )
        let ownerID = UUID()
        var request = makeRequest(id: "owned", sessionID: "ses_owned")
        request.appSessionID = ownerID
        let pending = Task { await center.submit(request) }
        await waitUntil { center.pending.count == 1 }
        XCTAssertEqual(center.pending.first?.appSessionID, ownerID)
        center.resolve(id: "owned", reply: .reject)
        _ = await pending.value
    }

    func testDuplicateRequestIDSharesTheSameDecision() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let first = makeRequest(id: "per_dup", sessionID: "ses_1")

        let decision = Task { await center.submit(first) }
        await waitUntil { center.pending.count == 1 }

        // Aynı istek ikinci bir koşudan da ulaşırsa erken bir yanıt üretilmez;
        // ikinci çağrı ilk karara ortak olur ve fazladan bekleyen açmaz.
        let duplicate = Task { await center.submit(first) }
        await waitUntil { center.duplicateJoinCount == 1 }

        center.resolve(id: "per_dup", reply: .once)

        let firstReply = await decision.value
        let duplicateReply = await duplicate.value
        XCTAssertEqual(firstReply, .once)
        XCTAssertEqual(duplicateReply, .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testRejectAllForOneSessionLeavesOtherSessionsAlone() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let firstDecision = Task {
            await center.submit(makeRequest(id: "per_1", sessionID: "ses_1"))
        }
        let secondDecision = Task {
            await center.submit(makeRequest(id: "per_2", sessionID: "ses_2"))
        }
        await waitUntil { center.pending.count == 2 }

        center.rejectAll(remoteSessionID: "ses_1")

        let firstReply = await firstDecision.value
        XCTAssertEqual(firstReply, .reject)
        XCTAssertEqual(center.pending.map(\.id), ["per_2"])

        center.resolve(id: "per_2", reply: .always)
        let secondReply = await secondDecision.value
        XCTAssertEqual(secondReply, .always)
    }

    func testRejectAllForAConversationAlsoClearsItsSubagentsRequests() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let conversation = UUID()

        // The turn's own request and one raised by a session it delegated to: the
        // delegated one carries the child session's id, so a cancellation that
        // only knew the parent's remote session would leave it on screen.
        var parentRequest = makeRequest(id: "per_parent", sessionID: "ses_parent")
        parentRequest.appSessionID = conversation
        var childRequest = makeRequest(id: "per_child", sessionID: "ses_child")
        childRequest.appSessionID = conversation
        childRequest.isDelegatedSession = true
        var foreignRequest = makeRequest(id: "per_other", sessionID: "ses_other")
        foreignRequest.appSessionID = UUID()

        let parentDecision = Task { await center.submit(parentRequest) }
        let childDecision = Task { await center.submit(childRequest) }
        let foreignDecision = Task { await center.submit(foreignRequest) }
        await waitUntil { center.pending.count == 3 }
        XCTAssertEqual(center.pending.first { $0.id == "per_child" }?.isDelegatedSession, true)

        center.rejectAll(remoteSessionID: "ses_parent", appSessionID: conversation)

        let parentReply = await parentDecision.value
        let childReply = await childDecision.value
        XCTAssertEqual(parentReply, .reject)
        XCTAssertEqual(childReply, .reject)
        XCTAssertEqual(center.pending.map(\.id), ["per_other"])

        center.resolve(id: "per_other", reply: .once)
        _ = await foreignDecision.value
    }

    func testResolvingAnUnknownRequestIsIgnored() {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        center.resolve(id: "per_missing", reply: .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testTitleFallsBackToTheRawToolNameForUnknownTools() {
        XCTAssertEqual(
            OpenCodePermissionRequest.title(for: "bash"),
            "Bash"
        )
        XCTAssertEqual(
            OpenCodePermissionRequest.title(for: "chatgpt-system_computer_click"),
            "Click"
        )
        XCTAssertEqual(
            OpenCodePermissionRequest.title(for: "chatgpt-system_session_authority_start"),
            "Grant computer authority"
        )
    }

    func testAutomaticReplySkipsTheQueueEntirely() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { toolName, _ in
                toolName.hasPrefix("chatgpt-system_") ? .once : nil
            },
            decisionTimeout: .seconds(60)
        )

        let reply = await center.submit(
            makeRequest(id: "per_auto", sessionID: "ses_1")
        )

        XCTAssertEqual(reply, .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// The level decides with the command in hand, so the request's patterns have
    /// to reach it — a decision made without them could not tell `git status` from
    /// `rm -rf`.
    func testTheAutomaticReplyReceivesTheRequestsPatterns() async {
        let seen = PatternsRecorder()
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, patterns in
                seen.record(patterns)
                return nil
            },
            decisionTimeout: .milliseconds(60)
        )

        _ = await center.submit(
            OpenCodePermissionRequest(
                id: "per_patterns",
                remoteSessionID: "ses_1",
                toolName: "bash",
                patterns: ["git status"],
                alwaysPatterns: ["git status*"],
                detail: nil
            )
        )

        XCTAssertEqual(seen.patterns, [["git status"]])
    }

    /// "Always allow" has to outlive the backend it was granted against: the
    /// server-side `always` dies with the server session, and re-asking after a
    /// restart for something the user already allowed is the bug this covers.
    func testAnAlwaysAllowCoversLaterIdenticalRequests() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )

        let first = Task { await center.submit(makeRequest(id: "per_1", sessionID: "ses_1")) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_1", reply: .always)
        _ = await first.value

        XCTAssertEqual(center.grants.count, 1)
        XCTAssertEqual(center.grants.first?.toolName, "chatgpt-system_computer_click")

        // The same request again, with no decision from anyone this time.
        let reply = await center.submit(makeRequest(id: "per_2", sessionID: "ses_1"))
        XCTAssertEqual(reply, .once, "A grant is a yes, not a queue entry")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAGrantDoesNotCoverADifferentCommand() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )

        let first = Task {
            await center.submit(
                OpenCodePermissionRequest(
                    id: "per_bash_1",
                    remoteSessionID: "ses_1",
                    toolName: "bash",
                    patterns: ["ls"],
                    alwaysPatterns: ["ls"],
                    detail: nil
                )
            )
        }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_bash_1", reply: .always)
        _ = await first.value

        let second = Task {
            await center.submit(
                OpenCodePermissionRequest(
                    id: "per_bash_2",
                    remoteSessionID: "ses_1",
                    toolName: "bash",
                    patterns: ["rm -rf build"],
                    alwaysPatterns: ["rm -rf build"],
                    detail: nil
                )
            )
        }
        await waitUntil { center.pending.map(\.id) == ["per_bash_2"] }
        XCTAssertEqual(center.pending.first?.patterns, ["rm -rf build"])
        center.resolve(id: "per_bash_2", reply: .reject)
        let reply = await second.value
        XCTAssertEqual(reply, .reject, "An unrelated command still requires a decision")
    }

    func testRevokingGrantsBringsTheQuestionsBack() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )

        let first = Task { await center.submit(makeRequest(id: "per_1", sessionID: "ses_1")) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_1", reply: .always)
        _ = await first.value

        center.revokeAllGrants()
        XCTAssertTrue(center.grants.isEmpty)

        let second = Task { await center.submit(makeRequest(id: "per_3", sessionID: "ses_1")) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_3", reply: .reject)

        let reply = await second.value
        XCTAssertEqual(reply, .reject)
    }

    func testResolvingEveryPendingRequestAtOnce() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )

        let decisions = ["per_a", "per_b", "per_c"].map { id in
            Task { await center.submit(makeRequest(id: id, sessionID: "ses_1")) }
        }
        await waitUntil { center.pending.count == 3 }

        center.resolveAll(reply: .reject)

        for decision in decisions {
            let reply = await decision.value
            XCTAssertEqual(reply, .reject)
        }
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAnUnansweredRequestIsRejectedWhenTheTimeoutExpires() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .milliseconds(50)
        )

        let reply = await center.submit(makeRequest(id: "per_timeout", sessionID: "ses_1"))

        XCTAssertEqual(
            reply,
            .reject,
            "A turn cannot hang forever because nobody looked at the window"
        )
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testADecisionBeforeTheTimeoutWins() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .milliseconds(400)
        )

        let decision = Task { await center.submit(makeRequest(id: "per_fast", sessionID: "ses_1")) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_fast", reply: .always)

        let reply = await decision.value
        XCTAssertEqual(reply, .always)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testExecutionHistoryIsAvailableWithoutInventingPermissionDecisions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-centre-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = ToolAuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60), auditLog: audit
        )
        await audit.recordExecution(ToolAuditLog.ExecutionRecord(
            timestamp: Date(), sessionID: "ses_1", activityID: "part_1",
            toolKind: .read, title: "Read file", detail: "source.swift", event: .completed
        ))
        let executions = await center.recentExecutions(limit: 10)
        XCTAssertEqual(executions.map(\.activityID), ["part_1"])
        let decisions = await center.recentDecisions(limit: 10)
        XCTAssertTrue(decisions.isEmpty)
    }

    private func makeRequest(id: String, sessionID: String) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(
            id: id,
            remoteSessionID: sessionID,
            toolName: "chatgpt-system_computer_click",
            patterns: ["*"],
            alwaysPatterns: ["chatgpt-system_computer_click*"],
            detail: "description: Click the Run button"
        )
    }

    /// Collects the patterns the level was asked about, from a `@Sendable` closure.
    private final class PatternsRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []

        func record(_ patterns: [String]) {
            lock.withLock { recorded.append(patterns) }
        }

        var patterns: [[String]] {
            lock.withLock { recorded }
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met in time")
    }
}

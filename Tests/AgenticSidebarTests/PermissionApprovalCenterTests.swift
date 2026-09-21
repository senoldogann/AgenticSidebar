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
        XCTAssertEqual(secondReply, .once, "An always grant must not persist in OpenCode")
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

    func testPendingRequestsAreScopedToOneConversation() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let first = UUID()
        let second = UUID()
        var mine = makeRequest(id: "per_mine", sessionID: "ses_1")
        mine.appSessionID = first
        var other = makeRequest(id: "per_other", sessionID: "ses_2")
        other.appSessionID = second
        let mineDecision = Task { await center.submit(mine) }
        let otherDecision = Task { await center.submit(other) }
        await waitUntil { center.pending.count == 2 }

        XCTAssertEqual(center.pendingRequests(for: first).map(\.id), ["per_mine"])
        XCTAssertEqual(center.pendingRequests(for: second).map(\.id), ["per_other"])
        XCTAssertTrue(center.pendingRequests(for: UUID()).isEmpty)

        center.resolve(id: "per_mine", reply: .once)
        center.resolve(id: "per_other", reply: .once)
        _ = await mineDecision.value
        _ = await otherDecision.value
    }

    func testScopedReinterpretLeavesTheOtherPanesQueueAlone() async {
        final class AutoReplyFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var enabled = false
            func enable() { lock.withLock { enabled = true } }
            func reply() -> ProviderPermissionReply? { lock.withLock { enabled ? .once : nil } }
        }
        let flag = AutoReplyFlag()
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in flag.reply() },
            decisionTimeout: .seconds(60)
        )
        let first = UUID()
        let second = UUID()
        var mine = makeRequest(id: "per_mine", sessionID: "ses_1")
        mine.appSessionID = first
        var other = makeRequest(id: "per_other", sessionID: "ses_2")
        other.appSessionID = second
        let mineDecision = Task { await center.submit(mine) }
        let otherDecision = Task { await center.submit(other) }
        await waitUntil { center.pending.count == 2 }

        flag.enable()
        center.reinterpretPendingRequests(appSessionID: first)

        let mineReply = await mineDecision.value
        XCTAssertEqual(mineReply, .once)
        XCTAssertEqual(center.pending.map(\.id), ["per_other"])

        center.reinterpretPendingRequests()
        let otherReply = await otherDecision.value
        XCTAssertEqual(otherReply, .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAGrantDoesNotCoverAnotherConversation() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let first = UUID()
        let second = UUID()
        var granted = makeRequest(id: "per_granted", sessionID: "ses_1")
        granted.appSessionID = first
        let grantedDecision = Task { await center.submit(granted) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_granted", reply: .always)
        _ = await grantedDecision.value
        XCTAssertEqual(center.grants.count, 1)

        // Aynı komut aynı sohbette sessizce geçer…
        var same = makeRequest(id: "per_same", sessionID: "ses_1")
        same.appSessionID = first
        let sameDecision = await center.submit(same)
        XCTAssertEqual(sameDecision, .once)
        XCTAssertTrue(center.pending.isEmpty)

        // …ama başka sohbette yeniden sorulur.
        var foreign = makeRequest(id: "per_foreign", sessionID: "ses_2")
        foreign.appSessionID = second
        let foreignDecision = Task { await center.submit(foreign) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_foreign", reply: .once)
        let foreignResult = await foreignDecision.value
        XCTAssertEqual(foreignResult, .once)
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
                detail: nil,
                delegationTarget: nil
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

    func testAlwaysApprovalCanBeRevokedWithoutLeavingABackendGrant() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )

        let first = Task { await center.submit(makeRequest(id: "first", sessionID: "same_server")) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "first", reply: .always)
        let backendReply = await first.value
        XCTAssertEqual(backendReply, .once, "OpenCode must never cache the app's grant")
        XCTAssertEqual(center.grants.count, 1)

        let coveredReply = await center.submit(
            makeRequest(id: "covered", sessionID: "same_server")
        )
        XCTAssertEqual(coveredReply, .once)
        center.revokeAllGrants()
        let afterRevoke = Task {
            await center.submit(makeRequest(id: "after_revoke", sessionID: "same_server"))
        }
        await waitUntil { center.pending.map(\.id) == ["after_revoke"] }
        center.resolve(id: "after_revoke", reply: .reject)
        let revokedReply = await afterRevoke.value
        XCTAssertEqual(revokedReply, .reject)
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
                    detail: nil,
                    delegationTarget: nil
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
                    detail: nil,
                    delegationTarget: nil
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

    func testRejectingEveryPendingRequestAtOnce() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )

        let decisions = ["per_a", "per_b", "per_c"].map { id in
            Task { await center.submit(makeRequest(id: id, sessionID: "ses_1")) }
        }
        await waitUntil { center.pending.count == 3 }

        center.rejectAll()

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
        XCTAssertEqual(reply, .once, "Backend receives one approval, app keeps the grant")
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
        await audit.recordExecution(
            ToolAuditLog.ExecutionRecord(
                timestamp: Date(), sessionID: "ses_1", activityID: "part_1",
                toolKind: .read, title: "Read file", detail: "source.swift", event: .completed
            ))
        let executions = await center.recentExecutions(limit: 10)
        XCTAssertEqual(executions.map(\.activityID), ["part_1"])
        let decisions = await center.recentDecisions(limit: 10)
        XCTAssertTrue(decisions.isEmpty)
    }

    func testRunningTurnKeepsItsPolicyAfterALevelChange() async {
        let live = LiveLevel()
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { toolName, patterns in
                live.reply(toolName: toolName, patterns: patterns)
            },
            decisionTimeout: .seconds(60)
        )
        let session = UUID()
        center.beginTurn(appSessionID: session, turnID: UUID(), policy: .ask)

        // Tur ortasında seviye değişir…
        live.setFullAccess()

        // …ama koşan turun isteği eski kuralla kullanıcıya sorulur, otomatik
        // onaylanmaz.
        var request = makeRequest(id: "per_turn", sessionID: "ses_1")
        request.appSessionID = session
        let decision = Task { await center.submit(request) }
        await waitUntil { center.pending.count == 1 }

        center.resolve(id: "per_turn", reply: .once)
        let turnReply = await decision.value
        XCTAssertEqual(turnReply, .once)
    }

    func testEndedTurnFollowsTheNewLevel() async {
        let live = LiveLevel()
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { toolName, patterns in
                live.reply(toolName: toolName, patterns: patterns)
            },
            decisionTimeout: .seconds(60)
        )
        let session = UUID()
        let turn = UUID()
        center.beginTurn(appSessionID: session, turnID: turn, policy: .ask)

        live.setFullAccess()
        center.endTurn(appSessionID: session, turnID: turn)

        // Tur politikası testi kabuk isteği kullanır: bilgisayar araçları
        // `fullAccess` altında otomatik onaylandığı için (`ask` turunda
        // bile beklemezler) tur sınırını kabuk isteği korur.
        var request = makeBashRequest(id: "per_next", sessionID: "ses_1")
        request.appSessionID = session
        let reply = await center.submit(request)
        XCTAssertEqual(reply, .once, "Tur bitince yeni seviye geçerli olmalı")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testStaleEndTurnDoesNotClearTheNewerTurn() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let session = UUID()
        let oldTurn = UUID()
        center.beginTurn(appSessionID: session, turnID: oldTurn, policy: .fullAccess)
        let newTurn = UUID()
        center.beginTurn(appSessionID: session, turnID: newTurn, policy: .ask)

        // Biten turun geç kapanışı yeni turun kaydını düşürmemeli.
        center.endTurn(appSessionID: session, turnID: oldTurn)

        var request = makeRequest(id: "per_new", sessionID: "ses_1")
        request.appSessionID = session
        let decision = Task { await center.submit(request) }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_new", reply: .reject)
        let newReply = await decision.value
        XCTAssertEqual(newReply, .reject)
    }

    func testReinterpretSkipsTheRunningTurn() async {
        let live = LiveLevel()
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { toolName, patterns in live.reply(toolName: toolName, patterns: patterns) },
            decisionTimeout: .seconds(60)
        )
        let running = UUID()
        let idle = UUID()
        // Bilgisayar araçları `fullAccess` altında otomatik onaylandığı
        // için bu tur-sınır testi kabuk istekleri kullanır.
        var runningRequest = makeBashRequest(id: "per_running", sessionID: "ses_1")
        runningRequest.appSessionID = running
        var idleRequest = makeBashRequest(id: "per_idle", sessionID: "ses_2")
        idleRequest.appSessionID = idle
        let runningDecision = Task { await center.submit(runningRequest) }
        let idleDecision = Task { await center.submit(idleRequest) }
        await waitUntil { center.pending.count == 2 }

        center.beginTurn(appSessionID: running, turnID: UUID(), policy: .ask)
        live.setFullAccess()
        center.reinterpretPendingRequests()

        // Koşan turun isteği eski kuralla beklemeye devam eder…
        await Task.yield()
        XCTAssertEqual(center.pending.map(\.id), ["per_running"])

        // …tur bitince bekleyen kalmaz, yeni kural sonraki turdadır.
        center.resolve(id: "per_running", reply: .once)
        let runningReply = await runningDecision.value
        let idleReply = await idleDecision.value
        XCTAssertEqual(runningReply, .once)
        XCTAssertEqual(idleReply, .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// `fullAccess` bilgisayar isteğini merkez üzerinden otomatik onaylar;
    /// `computer_run_js` kilidi uçtan uca kapalı kalır.
    func testFullAccessAutoApprovesComputerThroughCenter() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { toolName, patterns in
                ToolApprovalPolicy.fullAccess.automaticReply(for: toolName, patterns: patterns)
            },
            decisionTimeout: .seconds(60)
        )
        let reply = await center.submit(makeRequest(id: "per_computer_full", sessionID: "ses_1"))
        XCTAssertEqual(reply, .once)
        XCTAssertTrue(center.pending.isEmpty)

        var runJs = makeRequest(id: "per_runjs_full", sessionID: "ses_1")
        runJs = OpenCodePermissionRequest(
            id: runJs.id,
            remoteSessionID: "ses_1",
            toolName: "chatgpt-system_computer_run_js",
            patterns: ["*"],
            alwaysPatterns: ["chatgpt-system_computer_run_js*"],
            detail: "description: Run JavaScript",
            delegationTarget: nil
        )
        let runJsDecision = Task {
            await center.submit(runJs)
        }
        await waitUntil { center.pending.count == 1 }
        center.resolve(id: "per_runjs_full", reply: .reject)
        let runJsReply = await runJsDecision.value
        XCTAssertEqual(runJsReply, .reject)
    }

    /// Plan aşaması delegasyon yaptırımı: tek meşru hedef olan araştırma
    /// alt-ajanına delegasyon diyalogsuz bir kez onaylanır; başka hedef
    /// kullanıcıya sorulur. Sessiz `allow` backend'de bitti, karar burada verilir.
    func testTaskDelegationToResearchAgentIsApprovedOnceWithoutDialog() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let reply = await center.submit(
            OpenCodePermissionRequest(
                id: "per_task_research",
                remoteSessionID: "ses_1",
                toolName: "task",
                patterns: [],
                alwaysPatterns: [],
                detail: "subagent_type: agenticsidebar-research",
                delegationTarget: ManagedOpenCodeConfiguration.researchAgentName
            )
        )
        XCTAssertEqual(reply, .once)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testTaskDelegationToAnotherAgentAsksTheUser() async {
        let center = PermissionApprovalCenter(
            automaticReplyProvider: { _, _ in nil },
            decisionTimeout: .seconds(60)
        )
        let decision = Task {
            await center.submit(
                OpenCodePermissionRequest(
                    id: "per_task_build",
                    remoteSessionID: "ses_1",
                    toolName: "task",
                    patterns: [],
                    alwaysPatterns: [],
                    detail: "subagent_type: build",
                    delegationTarget: "build"
                )
            )
        }
        await waitUntil { center.pending.count == 1 }
        XCTAssertEqual(center.pending.first?.toolName, "task")
        center.resolve(id: "per_task_build", reply: .reject)
        let reply = await decision.value
        XCTAssertEqual(reply, .reject)
    }

    /// Tur ortasında değişen seviyeyi `@Sendable` kapatmadan okuyan kutu:
    /// `var` yakalama, gönderilebilir kapanıştan sonra değişince uyarı verir.
    private final class LiveLevel: @unchecked Sendable {
        private let lock = NSLock()
        private var level: ToolApprovalPolicy = .ask
        func setFullAccess() { lock.withLock { level = .fullAccess } }
        func reply(toolName: String, patterns: [String]) -> ProviderPermissionReply? {
            lock.withLock { level.automaticReply(for: toolName, patterns: patterns) }
        }
    }

    private func makeRequest(id: String, sessionID: String) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(
            id: id,
            remoteSessionID: sessionID,
            toolName: "chatgpt-system_computer_click",
            patterns: ["*"],
            alwaysPatterns: ["chatgpt-system_computer_click*"],
            detail: "description: Click the Run button",
            delegationTarget: nil
        )
    }

    /// Tur-seviye testleri için bilgisayar-dışı istek: `ask` sorar,
    /// `fullAccess` otomatik onaylar. Tur sınırı davranışı kabuk
    /// istekleriyle sınanır, böylece bilgisayar onayı seviyeye bağlı
    /// kalmaz.
    private func makeBashRequest(id: String, sessionID: String) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(
            id: id,
            remoteSessionID: sessionID,
            toolName: "bash",
            patterns: ["ls"],
            alwaysPatterns: ["ls*"],
            detail: "description: List files",
            delegationTarget: nil
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

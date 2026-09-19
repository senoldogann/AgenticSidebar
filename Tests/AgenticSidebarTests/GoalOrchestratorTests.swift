import Foundation
import XCTest

@testable import AgenticSidebar

/// Sahte oturum: meşgul bayrağı, aktivite sayacı ve gönderilen turlar.
/// Gerçek ajan yoktur; döngü `handleTurnFinished` ile el sürülür.
@MainActor
final class FakeGoalSession {
    var busy = false
    var activities = 0
    var submitted: [(text: String, mode: AgentMode)] = []
    var acceptance: PromptAcceptance = .started
    /// Bitmiş turun hatası; `nil` sağlıklı bitiş demektir.
    var turnFailure: AgentSessionError?

    func bridge() -> GoalOrchestrator.Bridge {
        GoalOrchestrator.Bridge(
            isBusy: { [weak self] _ in self?.busy ?? true },
            activityCount: { [weak self] _ in self?.activities ?? 0 },
            submit: { [weak self] _, text, mode, _ in
                guard let self else {
                    return .rejected
                }
                self.submitted.append((text: text, mode: mode))
                return self.acceptance
            },
            turnError: { [weak self] _ in self?.turnFailure }
        )
    }
}

/// Orkestratör: tam tur `done`, kırmızı kapı `fixing`, bütçe/durdurma
/// `failed`, reddedilen gönderim terminal hata, yarım koşu devam eder.
@MainActor
final class GoalOrchestratorTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() async throws {
        let urls = await MainActor.run { temporaryURLs }
        for url in urls {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        await MainActor.run { temporaryURLs = [] }
        try await super.tearDown()
    }

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url.appendingPathComponent("goal-run.json"))
        return url
    }

    private func packageDirectory() -> URL {
        let dir = scratchDirectory()
        try? "// swift-tools-version: 6.0".write(
            to: dir.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    private func runners(buildOK: Bool = true, testsOK: Bool = true) -> GoalRunners {
        GoalRunners(
            execute: { _, arguments, _ in
                if arguments == ["build"] {
                    return GoalCommandResult(
                        exitCode: buildOK ? 0 : 1,
                        outputTail: buildOK ? "build ok" : "build boom",
                        timedOut: false
                    )
                }
                return GoalCommandResult(
                    exitCode: testsOK ? 0 : 1,
                    outputTail: testsOK ? "tests ok" : "tests boom",
                    timedOut: false
                )
            },
            timeoutSeconds: 5
        )
    }

    private func waitFor(_ check: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !check(), Date() < deadline {
            try? await Task.sleep(for: .seconds(0.05))
        }
    }

    @discardableResult
    private func start(
        _ orchestrator: GoalOrchestrator,
        session: FakeGoalSession,
        package: URL,
        store: URL,
        budget: GoalBudget = GoalOrchestrator.defaultBudget,
        buildOK: Bool = true,
        testsOK: Bool = true
    ) -> Bool {
        orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: package,
            budget: budget,
            runners: runners(buildOK: buildOK, testsOK: testsOK),
            bridge: session.bridge(),
            storeURL: store
        )
    }

    /// Plan → derleme → doğrulama → inceleme → onay: üç tur, sırayla
    /// `.plan`, `.build`, `.review` kipinde gider.
    private func driveToReview(
        _ orchestrator: GoalOrchestrator,
        session: FakeGoalSession
    ) async {
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.lastReport != nil }
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.awaitingReview }
    }

    func testStartRefusesEmptyObjective() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let accepted = orchestrator.start(
            objective: "   ",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: package,
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(accepted)
        XCTAssertNil(orchestrator.engine)
    }

    func testStartRefusesNonPackageDirectory() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let accepted = orchestrator.start(
            objective: "Hedef",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: scratchDirectory(),
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(accepted)
        XCTAssertNil(orchestrator.engine)
    }

    func testStartRefusesBusySession() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.busy = true
        let accepted = start(orchestrator, session: session, package: packageDirectory(), store: temporaryURLs.last!)
        XCTAssertFalse(accepted)
        XCTAssertNil(orchestrator.engine)
    }

    func testStartRefusesToSubmitWhenGoalCannotBePersisted() throws {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let blocker = package.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let impossibleStore = blocker.appendingPathComponent("goal-run.json")

        let accepted = start(orchestrator, session: session, package: package, store: impossibleStore)

        XCTAssertFalse(accepted, "A goal must not start if its initial state cannot be saved")
        XCTAssertTrue(session.submitted.isEmpty, "No prompt may be sent for an unpersisted goal")
        XCTAssertNil(orchestrator.engine)
        XCTAssertNotNil(orchestrator.message)
    }

    func testFailedMidRunSaveStopsAutomaticContinuationAndPreservesLastSnapshot() throws {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let store = package.appendingPathComponent("goal-run.json")
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: store))
        XCTAssertEqual(session.submitted.map(\.mode), [.plan])
        let lastGoodSnapshot = try Data(contentsOf: store)

        let oldPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: package.path)[.posixPermissions] as? NSNumber
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: package.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: oldPermissions.intValue], ofItemAtPath: package.path
            )
        }

        orchestrator.handleTurnFinished()
        orchestrator.tick()
        orchestrator.handleTurnFinished()

        XCTAssertEqual(session.submitted.map(\.mode), [.plan], "A failed save must not dispatch another turn")
        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        XCTAssertFalse(orchestrator.isPolling)
        XCTAssertTrue(orchestrator.message?.contains("could not be saved") ?? false)
        XCTAssertEqual(try Data(contentsOf: store), lastGoodSnapshot)
    }

    func testDismissAfterSaveFailurePreservesRecoverableSnapshot() throws {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let store = package.appendingPathComponent("goal-run.json")
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: store))
        let lastGoodSnapshot = try Data(contentsOf: store)
        let oldPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: package.path)[.posixPermissions] as? NSNumber
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: oldPermissions.intValue], ofItemAtPath: package.path
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: package.path)
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        try FileManager.default.setAttributes([.posixPermissions: oldPermissions.intValue], ofItemAtPath: package.path)
        orchestrator.dismiss()
        XCTAssertEqual(try Data(contentsOf: store), lastGoodSnapshot)
    }

    func testFullLoopReachesDone() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let store = temporaryURLs.last ?? scratchDirectory().appendingPathComponent("goal-run.json")
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: store))
        XCTAssertEqual(session.submitted.count, 1)
        XCTAssertEqual(session.submitted.first?.mode, .plan)

        await driveToReview(orchestrator, session: session)
        XCTAssertEqual(session.submitted.map(\.mode), [.plan, .build, .review])
        XCTAssertEqual(orchestrator.lastReport?.summary, "build and tests passed")

        let criterion = orchestrator.engine?.run.criteria.first
        XCTAssertNotNil(criterion)
        orchestrator.setCriterion(id: criterion!.id, isMet: true)
        orchestrator.confirmReview(findings: 0)
        XCTAssertEqual(orchestrator.engine?.run.phase, .done)
        XCTAssertNil(GoalStore.load(from: store))
    }

    func testToolCallsAreCountedFromActivities() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        session.activities = 4
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.toolCallCount, 4)
    }

    func testRedGatesLeadToFixingThenBudgetStops() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let tight = GoalBudget(maxIterations: 0, maxDurationSeconds: 3_600, maxToolCalls: 300)
        XCTAssertTrue(
            start(
                orchestrator,
                session: session,
                package: package,
                store: temporaryURLs.last!,
                budget: tight,
                buildOK: false
            ))
        await driveToReview(orchestrator, session: session)
        XCTAssertEqual(orchestrator.lastReport?.buildSucceeded, false)
        let criterion = orchestrator.engine?.run.criteria.first
        orchestrator.setCriterion(id: criterion!.id, isMet: true)
        orchestrator.confirmReview(findings: 0)
        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        if case .budgetExceeded = orchestrator.engine?.run.failureReason {
        } else {
            XCTFail("expected budgetExceeded, got \(String(describing: orchestrator.engine?.run.failureReason))")
        }
    }

    func testConfirmReviewRequiresMetCriteria() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        await driveToReview(orchestrator, session: session)
        orchestrator.confirmReview(findings: 0)
        XCTAssertTrue(orchestrator.awaitingReview)
        XCTAssertNotNil(orchestrator.message)
    }

    func testRejectedSubmitFailsRun() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.acceptance = .rejected
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
    }

    /// Sağlayıcı kesintisiyle biten tur faz ilerletmez: hatalı plan turunun
    /// ardından derleme turu gönderilmez, koşu gerekçeli terminal hataya düşer.
    func testFailedPlanTurnFailsRunWithoutSubmittingBuild() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.turnFailure = .transportFailure
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        XCTAssertEqual(session.submitted.count, 1)

        orchestrator.handleTurnFinished()

        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        XCTAssertEqual(
            orchestrator.engine?.run.failureReason,
            .unrecoverable(detail: "the planning turn failed: transportFailure")
        )
        XCTAssertEqual(session.submitted.count, 1, "hatalı turun ardından tur gönderilmemeli")
    }

    /// Döngü ortasında kesilen tur da durdurur: plan sağlıklı bitti
    /// (derleme gönderildi), derleme turu kesildi.
    func testFailedBuildTurnStopsLoop() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))

        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
        XCTAssertEqual(session.submitted.count, 2)

        session.turnFailure = .streamInterrupted
        orchestrator.handleTurnFinished()

        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        XCTAssertEqual(
            orchestrator.engine?.run.failureReason,
            .unrecoverable(detail: "the building turn failed: streamInterrupted")
        )
        XCTAssertEqual(session.submitted.count, 2, "hatalı turun ardından tur gönderilmemeli")
    }

    func testPauseResumeStop() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        orchestrator.pause()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
        // Duraklatmada tur bitişi işlenmez.
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
        orchestrator.resume()
        XCTAssertNotEqual(orchestrator.engine?.run.phase, .paused)
        orchestrator.stop()
        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        if case .cancelledByUser = orchestrator.engine?.run.failureReason {
        } else {
            XCTFail("expected cancelledByUser")
        }
        XCTAssertFalse(orchestrator.isPolling, "Durdurulan koşu anketi bırakmalı")
    }

    func testTerminalTickStopsPolling() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        await driveToReview(orchestrator, session: session)
        let criterion = orchestrator.engine?.run.criteria.first
        XCTAssertNotNil(criterion)
        orchestrator.setCriterion(id: criterion!.id, isMet: true)
        orchestrator.confirmReview(findings: 0)
        XCTAssertEqual(orchestrator.engine?.run.phase, .done)
        orchestrator.tick()
        XCTAssertFalse(orchestrator.isPolling, "Terminal koşu saniyede bir uyanmamalı")
    }

    func testSecondStartRefusedWhileActive() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        let again = start(orchestrator, session: session, package: package, store: temporaryURLs.last!)
        XCTAssertFalse(again)
    }

    func testStartRefusedWhenAnotherPaneRuns() throws {
        let store = scratchDirectory().appendingPathComponent("goal-run.json")
        let package = packageDirectory()
        var engine = GoalEngine(
            objective: "Diğer bölme",
            budget: GoalOrchestrator.defaultBudget,
            startedAt: Date()
        )
        XCTAssertTrue(
            engine.begin(
                criteria: [AcceptanceCriterion(id: UUID(), text: "x", isMet: false)],
                date: Date()
            ))
        try GoalStore.save(
            GoalStoredRun(
                run: engine.run,
                budget: GoalOrchestrator.defaultBudget,
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectoryPath: package.path,
                updatedAt: Date()
            ),
            to: store
        )
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let refused = start(orchestrator, session: session, package: package, store: store)
        XCTAssertFalse(refused)
        XCTAssertNil(orchestrator.engine)
        XCTAssertTrue(session.submitted.isEmpty)
    }

    func testResumeStoredRunReverifies() async {
        let store = scratchDirectory().appendingPathComponent("goal-run.json")
        let package = packageDirectory()
        var engine = GoalEngine(
            objective: "Yarım hedef",
            budget: GoalOrchestrator.defaultBudget,
            startedAt: Date()
        )
        XCTAssertTrue(
            engine.begin(
                criteria: [AcceptanceCriterion(id: UUID(), text: "x", isMet: false)],
                date: Date()
            ))
        XCTAssertTrue(engine.didFinishPlan(date: Date()))
        XCTAssertTrue(engine.didFinishBuild(date: Date()))
        try? GoalStore.save(
            GoalStoredRun(
                run: engine.run,
                budget: GoalOrchestrator.defaultBudget,
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectoryPath: package.path,
                updatedAt: Date()
            ),
            to: store
        )
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        orchestrator.noticeStoredRun(storeURL: store, runners: runners(), bridge: session.bridge())
        XCTAssertEqual(orchestrator.resumableObjective, "Yarım hedef")
        orchestrator.resumeStoredRun()
        // `verifying` fazı `building`e indirgenir, doğrulama yeniden koşar.
        await waitFor { orchestrator.lastReport != nil }
        XCTAssertEqual(orchestrator.lastReport?.summary, "build and tests passed")
    }

    func testResumePreservesRunThatBecomesCorruptAfterNotice() throws {
        let package = packageDirectory()
        let store = temporaryURLs.last!
        let owner = GoalOrchestrator()
        let session = FakeGoalSession()
        XCTAssertTrue(start(owner, session: session, package: package, store: store))

        let resumed = GoalOrchestrator()
        resumed.noticeStoredRun(storeURL: store, runners: runners(), bridge: session.bridge())
        XCTAssertNotNil(resumed.resumableObjective)

        // A partial external write between discovery and Resume must not
        // destroy the only recoverable bytes when the user clicks Resume.
        let damaged = Data("incomplete-goal-json{{".utf8)
        try damaged.write(to: store, options: .atomic)
        resumed.resumeStoredRun()

        XCTAssertEqual(try Data(contentsOf: store), damaged)
        XCTAssertNil(resumed.engine)
    }

    func testUpdateWorkingDirectoryValidation() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        orchestrator.updateWorkingDirectory(path: scratchDirectory().path)
        XCTAssertNotNil(orchestrator.message)
        XCTAssertEqual(orchestrator.workingDirectoryPath, package.path)
        orchestrator.updateWorkingDirectory(path: package.path)
        XCTAssertNil(orchestrator.message)
    }

    func testResumeRestoresStoredPendingAction() {
        let store = scratchDirectory().appendingPathComponent("goal-run.json")
        let package = packageDirectory()
        var engine = GoalEngine(
            objective: "Kayıtlı eylem",
            budget: GoalOrchestrator.defaultBudget,
            startedAt: Date()
        )
        XCTAssertTrue(
            engine.begin(
                criteria: [AcceptanceCriterion(id: UUID(), text: "x", isMet: false)],
                date: Date()
            ))
        XCTAssertTrue(engine.didFinishPlan(date: Date()))
        // Derleme eylemi diske yazılmış ama tur gönderilememiş gibi kaydet.
        try? GoalStore.save(
            GoalStoredRun(
                run: engine.run,
                budget: GoalOrchestrator.defaultBudget,
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectoryPath: package.path,
                pendingAction: .submitBuild,
                updatedAt: Date()
            ),
            to: store
        )
        let second = GoalOrchestrator()
        let secondSession = FakeGoalSession()
        second.noticeStoredRun(storeURL: store, runners: runners(), bridge: secondSession.bridge())
        second.resumeStoredRun()
        // Plan tekrarlanmaz, kayıtlı derleme eylemi doğrudan gider.
        XCTAssertEqual(secondSession.submitted.map(\.mode), [.build])
    }

    func testDefaultActionMapping() {
        XCTAssertEqual(GoalOrchestrator.defaultAction(for: .decomposing), .submitPlan)
        XCTAssertEqual(GoalOrchestrator.defaultAction(for: .planning), .submitPlan)
        XCTAssertEqual(GoalOrchestrator.defaultAction(for: .building), .submitBuild)
        XCTAssertEqual(GoalOrchestrator.defaultAction(for: .verifying), .verify)
        XCTAssertEqual(GoalOrchestrator.defaultAction(for: .reviewing), .submitReview)
        XCTAssertEqual(GoalOrchestrator.defaultAction(for: .fixing), .verify)
        XCTAssertNil(GoalOrchestrator.defaultAction(for: .paused))
        XCTAssertNil(GoalOrchestrator.defaultAction(for: .done))
        XCTAssertNil(GoalOrchestrator.defaultAction(for: .failed))
    }

    func testTurnPromptsCarryObjective() {
        let objective = "Şeffaf kaydırma çubuğu"
        XCTAssertTrue(GoalOrchestrator.planText(objective: objective).contains(objective))
        XCTAssertTrue(GoalOrchestrator.buildText(objective: objective).contains(objective))
        XCTAssertTrue(GoalOrchestrator.reviewText(objective: objective).contains(objective))
        let fix = GoalOrchestrator.fixText(objective: objective, reasons: ["build failed"])
        XCTAssertTrue(fix.contains(objective))
        XCTAssertTrue(fix.contains("build failed"))
    }

    func testVerifyFinishingWhilePausedDoesNotDeadlock() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let slow = GoalRunners(
            execute: { _, arguments, _ in
                try? await Task.sleep(for: .milliseconds(300))
                if arguments == ["build"] {
                    return GoalCommandResult(exitCode: 0, outputTail: "build ok", timedOut: false)
                }
                return GoalCommandResult(exitCode: 0, outputTail: "tests ok", timedOut: false)
            },
            timeoutSeconds: 5
        )
        let store = temporaryURLs.last!
        orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: package,
            budget: GoalOrchestrator.defaultBudget,
            runners: slow,
            bridge: session.bridge(),
            storeURL: store
        )
        orchestrator.handleTurnFinished()
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.isVerifying }
        orchestrator.pause()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
        await waitFor({ !orchestrator.isVerifying }, timeout: 5)
        XCTAssertFalse(
            orchestrator.isVerifying,
            "Paused verify must release the gate instead of deadlocking the loop"
        )
        orchestrator.resume()
        await waitFor({ orchestrator.lastReport != nil }, timeout: 5)
        XCTAssertNotNil(orchestrator.lastReport)
    }

    func testReportContainsSections() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        let report = orchestrator.currentReport()
        XCTAssertTrue(report?.contains("# Goal Report") ?? false)
        XCTAssertTrue(report?.contains("## Acceptance criteria") ?? false)
        XCTAssertTrue(report?.contains("## Verification") ?? false)
        XCTAssertTrue(report?.contains("## Log") ?? false)
    }

    /// Ret görünürlüğü: paket-olmayan dizin reddinde istek taşınır, panel
    /// görünür olur, ileti kurulur — besteci taslağı koruduğu için metin
    /// kaybolmaz, panel de nedeni gösterir.
    func testNonPackageRefusalStoresFailedRequest() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let accepted = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: scratchDirectory(),
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(accepted)
        XCTAssertNil(orchestrator.engine)
        XCTAssertEqual(orchestrator.failedRequest?.objective, "Pencere opaklığı kaydıcısı")
        XCTAssertNotNil(orchestrator.message)
        XCTAssertTrue(orchestrator.hasVisiblePanel, "Ret panelde görünmeli")
    }

    /// Meşgul oturum reddi de görünür kalır.
    func testBusyRefusalStoresFailedRequest() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.busy = true
        let accepted = start(orchestrator, session: session, package: packageDirectory(), store: temporaryURLs.last!)
        XCTAssertFalse(accepted)
        XCTAssertNil(orchestrator.engine)
        XCTAssertNotNil(orchestrator.failedRequest, "Meşgul reddi taşınmalı")
        XCTAssertTrue(orchestrator.hasVisiblePanel)
    }

    /// Yeniden deneme: aynı hedef paket dizininde başlar, ret temizlenir.
    func testRetryFailedGoalSucceedsInPackageDirectory() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let rejected = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: scratchDirectory(),
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(rejected)
        XCTAssertTrue(orchestrator.retryFailedGoal(in: packageDirectory()))
        XCTAssertNotNil(orchestrator.engine)
        XCTAssertNil(orchestrator.failedRequest, "Başarı reti temizler")
        XCTAssertNil(orchestrator.message)
    }

    /// Ret yokken yeniden deneme sessizce `false` döner.
    func testRetryWithoutFailureReturnsFalse() {
        let orchestrator = GoalOrchestrator()
        XCTAssertFalse(orchestrator.retryFailedGoal(in: packageDirectory()))
    }

    /// `dismiss` reti de kaldırır; panel kapanır.
    func testDismissClearsFailure() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let accepted = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: scratchDirectory(),
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(accepted)
        orchestrator.dismiss()
        XCTAssertNil(orchestrator.failedRequest)
        XCTAssertNil(orchestrator.message)
        XCTAssertFalse(orchestrator.hasVisiblePanel)
    }

    /// `clearFailure` koşuya dokunmaz: aktif koşunun iletisi korunur.
    func testClearFailurePreservesRunningGoal() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        orchestrator.clearFailure()
        XCTAssertNotNil(orchestrator.engine, "Koşan hedef etkilenmemeli")
    }

    /// Ret temizliği: kart kapanır, panel gizlenir.
    func testClearFailureHidesPanel() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let accepted = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: scratchDirectory(),
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(accepted)
        orchestrator.clearFailure()
        XCTAssertNil(orchestrator.failedRequest)
        XCTAssertNil(orchestrator.message)
        XCTAssertFalse(orchestrator.hasVisiblePanel)
    }
}

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
    /// Tur kullanıcıyı bekliyor mu (aracı sorusu / onay kuyruğu simülasyonu).
    var waitingForUser = false
    /// Son review yanıtı: üretim talimatı `CRITICAL_HIGH_COUNT` satırını
    /// zorunlu kılar, işaret yoksa kapı bilinmeyen sayar ve yeniden inceler.
    var reviewText: String? = "No issues found.\nCRITICAL_HIGH_COUNT: 0"

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
            turnError: { [weak self] _ in self?.turnFailure },
            lastAssistantText: { [weak self] _ in self?.reviewText },
            cancel: { _ in },
            isWaitingForUser: { [weak self] _ in self?.waitingForUser ?? false }
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
        // Manuel review kapısı testleri: otonom devam kapalı, eski onay akışı.
        orchestrator.setAutoContinue(false)
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.lastReport != nil }
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.awaitingReview }
    }

    /// Otonom drive: review onayı beklemez, bitene kadar kendi kendine akar.
    private func driveAutoToTerminal(
        _ orchestrator: GoalOrchestrator,
        session: FakeGoalSession
    ) async {
        orchestrator.setAutoContinue(true)
        orchestrator.handleTurnFinished()
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.lastReport != nil }
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.engine?.run.isTerminal == true }
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

    func testStartAcceptsXcodeProjectDirectory() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let dir = scratchDirectory()
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("OSJarvis.xcodeproj"),
            withIntermediateDirectories: true
        )
        let accepted = orchestrator.start(
            objective: "Hedef",
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectory: dir,
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertTrue(accepted)
        XCTAssertNotNil(orchestrator.engine)
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
        // Kart görünür kalmalı: panel yalnız `failedRequest` doluyken çizer ve
        // yeniden deneme yolunu yalnız bu istek açar.
        XCTAssertNotNil(orchestrator.failedRequest, "The panel cannot show or retry an invisible failure")
        XCTAssertEqual(orchestrator.failedRequest?.objective, "Pencere opaklığı kaydıcısı")
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

    /// Geçici sağlayıcı kesintisiyle biten tur aynı turu yeniden dener:
    /// hatalı plan turunun ardından koşu ölmez, plan turu tekrar gönderilir.
    func testFailedPlanTurnFailsRunWithoutSubmittingBuild() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.turnFailure = .transportFailure
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        XCTAssertEqual(session.submitted.count, 1)

        orchestrator.handleTurnFinished()

        XCTAssertEqual(orchestrator.engine?.run.phase, .planning, "geçici hata fazı değiştirmemeli")
        XCTAssertEqual(session.submitted.count, 2, "aynı tur yeniden gönderilmeli")
        XCTAssertEqual(session.submitted.last?.mode, .plan)
        // Hata temizlenince döngü kaldığı yerden sürer.
        session.turnFailure = nil
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
    }

    /// Döngü ortasında kesilen tur da aynı turu yeniden dener: plan sağlıklı
    /// bitti (derleme gönderildi), derleme turu kesildi, derleme tekrar gider.
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

        XCTAssertEqual(orchestrator.engine?.run.phase, .building, "geçici hata fazı değiştirmemeli")
        XCTAssertEqual(session.submitted.count, 3, "derleme turu yeniden gönderilmeli")
        XCTAssertEqual(session.submitted.last?.mode, .build)
        session.turnFailure = nil
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .verifying)
    }

    /// Kalıcı hata (kimlik yok) koşuyu durdurur: yeniden deneme yok.
    func testPermanentTurnErrorFailsRun() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.turnFailure = .missingCredential
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        XCTAssertEqual(session.submitted.count, 1)

        orchestrator.handleTurnFinished()

        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        XCTAssertEqual(session.submitted.count, 1, "kalıcı hatada tur gönderilmemeli")
    }

    /// Bağlam taşması kalıcıdır: koşu durur, yeniden deneme yok.
    func testContextLimitTurnErrorFailsRun() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.turnFailure = .contextLimitExceeded
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))

        orchestrator.handleTurnFinished()

        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        XCTAssertEqual(session.submitted.count, 1)
    }

    /// Sürekli geçici hata bütçeyi bitirir: koşu `budgetExceeded` ile durur.
    func testRepeatedTransientErrorsExhaustBudget() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.turnFailure = .transportFailure
        let package = packageDirectory()
        let budget = GoalBudget(maxIterations: 0, maxDurationSeconds: 3_600, maxToolCalls: 300)
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!, budget: budget))

        orchestrator.handleTurnFinished()

        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
        if case .budgetExceeded = orchestrator.engine?.run.failureReason {
        } else {
            XCTFail("expected budgetExceeded, got \(String(describing: orchestrator.engine?.run.failureReason))")
        }
    }

    /// Hata sınıflandırması: geçiciler retry, kalıcılar fail.
    func testRetryableTurnErrorClassification() {
        XCTAssertTrue(GoalOrchestrator.isRetryableTurnError(.transportFailure))
        XCTAssertTrue(GoalOrchestrator.isRetryableTurnError(.streamInterrupted))
        XCTAssertTrue(GoalOrchestrator.isRetryableTurnError(.rateLimited))
        XCTAssertTrue(GoalOrchestrator.isRetryableTurnError(.providerUnavailable))
        XCTAssertFalse(GoalOrchestrator.isRetryableTurnError(.missingCredential))
        XCTAssertFalse(GoalOrchestrator.isRetryableTurnError(.authenticationFailure))
        XCTAssertFalse(GoalOrchestrator.isRetryableTurnError(.contextLimitExceeded))
        XCTAssertFalse(GoalOrchestrator.isRetryableTurnError(.unsupportedCapability))
        XCTAssertFalse(GoalOrchestrator.isRetryableTurnError(.unexpectedBackendResponse))
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

    /// Duraklatma oturumu kesmez: koşan tur korunur, bitişi `resume`
    /// sonrasına ertelenir, devamında derleme turu gelir (plan tekrarı yok).
    func testPauseKeepsTurnAndResumesWithoutResubmit() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        XCTAssertEqual(session.submitted.count, 1, "Başlangıç plan turunu göndermeli")
        orchestrator.pause()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
        // Duraklatmada tur bitişi ertelenir: faz kımıldamaz, yeni gönderim olmaz.
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
        XCTAssertEqual(session.submitted.count, 1, "Duraklatma yeni tur göndermemeli")
        orchestrator.resume()
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
        XCTAssertEqual(session.submitted.count, 2, "Devamında derleme turu gelmeli")
        XCTAssertEqual(session.submitted.last?.mode, .build, "Plan tekrar gönderilmemeli")
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

    /// Çoklu-goal: farklı sohbetler (farklı store dosyaları) eşzamanlı koşar,
    /// birbirini kilitlemez. Aynı sohbetin dosyası doluyken ret sürer
    /// (`testStartRefusedWhenAnotherPaneRuns`).
    func testConcurrentGoalsInDifferentSessionsBothStart() {
        let package = packageDirectory()
        let storeA = scratchDirectory().appendingPathComponent("goal-run-aaaa.json")
        let storeB = scratchDirectory().appendingPathComponent("goal-run-bbbb.json")
        let first = GoalOrchestrator()
        let second = GoalOrchestrator()
        // Geçici nesne çağrı sonunda ölür ve köprünün zayıf başvurusu `nil`
        // kalırdı (WAE uyarısı); oturumlar yerelde tutulur.
        let firstSession = FakeGoalSession()
        let secondSession = FakeGoalSession()
        XCTAssertTrue(start(first, session: firstSession, package: package, store: storeA))
        XCTAssertTrue(start(second, session: secondSession, package: package, store: storeB))
        XCTAssertNotNil(first.engine)
        XCTAssertNotNil(second.engine)
    }

    func testSessionFileNamesAreUniquePerSession() {
        let a = GoalStore.fileName(for: UUID())
        let b = GoalStore.fileName(for: UUID())
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("goal-run-"))
        XCTAssertTrue(a.hasSuffix(".json"))
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

    /// Çakışma bayrağı + takılı kayıt atma: aynı sohbetin dosyasında
    /// terminal-olmayan koşu dururken ret takılı-goal kartıdır; discard dosyayı
    /// siler, kartı kapatır ve aynı `/goal` yeniden başlayabilir (kilitlenme yok).
    func testStaleConflictDiscardUnblocksNewGoal() throws {
        let store = scratchDirectory().appendingPathComponent("goal-run.json")
        let package = packageDirectory()
        var engine = GoalEngine(
            objective: "Takılı koşu",
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
        XCTAssertFalse(start(orchestrator, session: session, package: package, store: store))
        XCTAssertTrue(orchestrator.showsStaleGoalConflict)

        orchestrator.discardStaleStoredGoal()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertNil(orchestrator.failedRequest)
        XCTAssertNil(orchestrator.message)
        XCTAssertFalse(orchestrator.showsStaleGoalConflict)
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: store))
    }

    /// Koşan hedefe discard dokunmaz: dosya ve motor yerinde kalır.
    func testDiscardStaleStoredGoalKeepsRunningGoal() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let store = temporaryURLs.last!
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: store))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))

        orchestrator.discardStaleStoredGoal()

        XCTAssertNotNil(orchestrator.engine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(orchestrator.showsStaleGoalConflict)
    }

    /// Paket-dizin reddi çakışma değildir: discard düğmesi çizilmez.
    func testStaleConflictFlagFalseForPackageRefusal() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        XCTAssertFalse(start(orchestrator, session: session, package: scratchDirectory(), store: temporaryURLs.last!))
        XCTAssertNotNil(orchestrator.failedRequest)
        XCTAssertFalse(orchestrator.showsStaleGoalConflict)
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

    /// Tekli kipte sohbet değişimi: önceki sohbetin ret kartı/iletisi yeni
    /// sohbetin yarım koşusunu fark edince temizlenir, yoksa kart yanlış
    /// sohbete sızar ya da yeni koşunun önü kapanır.
    func testNoticeStoredRunOnSessionSwitchClearsStaleFailure() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        // Oturum A: paket reddi → ret kartı + ileti.
        XCTAssertFalse(start(orchestrator, session: session, package: scratchDirectory(), store: temporaryURLs.last!))
        XCTAssertNotNil(orchestrator.failedRequest)
        XCTAssertNotNil(orchestrator.message)
        // Oturum B: diskte yarım koşu.
        let sessionB = UUID()
        let package = packageDirectory()
        var engine = GoalEngine(
            objective: "B hedefi",
            budget: GoalOrchestrator.defaultBudget,
            startedAt: Date()
        )
        XCTAssertTrue(
            engine.begin(
                criteria: [AcceptanceCriterion(id: UUID(), text: "x", isMet: false)],
                date: Date()
            ))
        let storeB = scratchDirectory().appendingPathComponent("goal-run.json")
        try? GoalStore.save(
            GoalStoredRun(
                run: engine.run,
                budget: GoalOrchestrator.defaultBudget,
                sessionID: sessionB,
                speedMode: .normal,
                mode: .build,
                workingDirectoryPath: package.path,
                updatedAt: Date()
            ),
            to: storeB
        )
        orchestrator.noticeStoredRun(storeURL: storeB, runners: runners(), bridge: session.bridge())
        XCTAssertEqual(orchestrator.sessionID, sessionB)
        XCTAssertEqual(orchestrator.resumableObjective, "B hedefi")
        XCTAssertNil(orchestrator.failedRequest)
        XCTAssertNil(orchestrator.message)
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

    /// Meşgul oturum kuyruktur, ret değil: istek tur bitimine taşınır.
    func testBusyRefusalStoresFailedRequest() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.busy = true
        let accepted = start(orchestrator, session: session, package: packageDirectory(), store: temporaryURLs.last!)
        XCTAssertFalse(accepted)
        XCTAssertNil(orchestrator.engine)
        XCTAssertNotNil(orchestrator.failedRequest, "Meşgul reddi taşınmalı")
        XCTAssertTrue(orchestrator.failedRequest?.autoStart == true, "Meşgul reddi otomatik başlatılmalı")
        XCTAssertTrue(orchestrator.hasVisiblePanel)
    }

    /// Kuyruk tur koşarken bekler, tur bitince kendiliğinden başlar.
    func testQueuedGoalAutoStartsWhenTurnFinishes() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.busy = true
        let package = packageDirectory()
        let store = temporaryURLs.last!
        XCTAssertFalse(start(orchestrator, session: session, package: package, store: store))
        XCTAssertNil(orchestrator.engine)

        orchestrator.tick()
        XCTAssertNil(orchestrator.engine, "Tur koşarken başlanmamalı")

        session.busy = false
        orchestrator.tick()
        XCTAssertNotNil(orchestrator.engine, "Tur bitince kuyruk başlamalı")
        XCTAssertNil(orchestrator.failedRequest, "Başarı kuyruğu temizler")
    }

    /// Kuyruk iptal edilince tur bitse de başlanmaz.
    func testCancelledQueueDoesNotAutoStart() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        session.busy = true
        XCTAssertFalse(start(orchestrator, session: session, package: packageDirectory(), store: temporaryURLs.last!))
        orchestrator.clearFailure()
        session.busy = false
        orchestrator.tick()
        XCTAssertNil(orchestrator.engine)
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

    /// Ret oturumu taşır: panel oturuma göre kapılandığı için kart yalnız
    /// reddedilen sohbette çizilir, başka sohbete sızmaz.
    func testFailedRequestCarriesSessionID() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let sessionID = UUID()
        let accepted = orchestrator.start(
            objective: "Pencere opaklığı kaydıcısı",
            sessionID: sessionID,
            speedMode: .normal,
            mode: .build,
            workingDirectory: scratchDirectory(),
            runners: runners(),
            bridge: session.bridge(),
            storeURL: temporaryURLs.last
        )
        XCTAssertFalse(accepted, "Paketsiz dizin reddedilmeli")
        XCTAssertEqual(orchestrator.failedRequest?.sessionID, sessionID)
    }

    /// Devam önerisi koşunun oturumunu taşır: panel yalnız o sohbette çizilir.
    func testNoticeStoredRunCarriesSessionID() {
        let package = packageDirectory()
        let store = temporaryURLs.last!
        let sessionID = UUID()
        try? GoalStore.save(
            GoalStoredRun(
                run: GoalEngine(
                    objective: "Yarım hedef",
                    budget: GoalOrchestrator.defaultBudget,
                    startedAt: Date()
                ).run,
                budget: GoalOrchestrator.defaultBudget,
                sessionID: sessionID,
                speedMode: .normal,
                mode: .build,
                workingDirectoryPath: package.path,
                updatedAt: Date()
            ),
            to: store
        )
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        orchestrator.noticeStoredRun(
            storeURL: store,
            runners: runners(),
            bridge: session.bridge()
        )
        XCTAssertEqual(orchestrator.resumableObjective, "Yarım hedef")
        XCTAssertEqual(orchestrator.sessionID, sessionID)
    }

    /// Otonom devam (öntanımlı): review turu bitince kullanıcı onayı
    /// beklenmez, doğrulama yeşilse koşu kendiliğinden `done` olur.
    func testAutoContinueReachesDoneWithoutManualConfirm() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        XCTAssertTrue(orchestrator.autoContinue, "Otonom devam öntanımlı açık olmalı")
        await driveAutoToTerminal(orchestrator, session: session)
        XCTAssertEqual(orchestrator.engine?.run.phase, .done)
        XCTAssertFalse(orchestrator.awaitingReview, "Otonom koşu review onayı beklememeli")
        XCTAssertEqual(session.submitted.map(\.mode), [.plan, .build, .review])
    }

    /// Otonom devam kırmızı kapıda düzeltmeye gider: build kırmızıysa review
    /// sonrası fix turu kendiliğinden kuyruklanır.
    func testAutoContinueFixesOnRedGates() async {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let tight = GoalBudget(maxIterations: 5, maxDurationSeconds: 3_600, maxToolCalls: 300)
        XCTAssertTrue(
            start(
                orchestrator,
                session: session,
                package: package,
                store: temporaryURLs.last!,
                budget: tight,
                buildOK: false
            ))
        orchestrator.setAutoContinue(true)
        orchestrator.handleTurnFinished()
        orchestrator.handleTurnFinished()
        await waitFor { orchestrator.lastReport != nil }
        orchestrator.handleTurnFinished()
        await waitFor { session.submitted.count >= 4 }
        XCTAssertEqual(orchestrator.engine?.run.phase, .fixing, "Kırmızı kapı otonom fix fazına geçmeli")
        XCTAssertEqual(session.submitted.map(\.mode), [.plan, .build, .review, .build])
        XCTAssertFalse(orchestrator.awaitingReview)
    }

    /// Hedef güncelleme: motorun hedefi değişir, sonraki tur güncel metni
    /// kullanır (Codex-tarzı "içeriği güncelle, ajan güncel içerikle devam
    /// etsin").
    func testUpdateObjectiveChangesObjective() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        XCTAssertTrue(start(orchestrator, session: session, package: package, store: temporaryURLs.last!))
        orchestrator.setAutoContinue(false)
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
        orchestrator.updateObjective("Güncel hedef: kaydırma çubuğu opaklığı")
        XCTAssertEqual(orchestrator.engine?.run.objective, "Güncel hedef: kaydırma çubuğu opaklığı")
        orchestrator.updateObjective("   ")
        XCTAssertEqual(
            orchestrator.engine?.run.objective, "Güncel hedef: kaydırma çubuğu opaklığı",
            "Boş güncelleme hedefi değiştirmemeli")
    }

    /// Duraklat oturumu kesmez: `cancel` çağrılmaz, koşan tur korunur,
    /// bitişi `resume` sonrasına ertelenir, faz duraklatılmış kalır.
    func testPauseCancelsRunningTurn() {
        let orchestrator = GoalOrchestrator()
        var cancelled: [UUID] = []
        let session = FakeGoalSession()
        let package = packageDirectory()
        let sessionID = UUID()
        var bridge = session.bridge()
        let baseCancel = bridge.cancel
        bridge.cancel = { id in
            cancelled.append(id)
            baseCancel(id)
        }
        XCTAssertTrue(
            orchestrator.start(
                objective: "Hedef",
                sessionID: sessionID,
                speedMode: .normal,
                mode: .build,
                workingDirectory: package,
                runners: runners(),
                bridge: bridge,
                storeURL: temporaryURLs.last
            ))
        orchestrator.pause()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
        XCTAssertTrue(cancelled.isEmpty, "Duraklat oturumu kesmemeli")
        // Ertelenen bitiş duraklatmada işlenmez.
        orchestrator.handleTurnFinished()
        XCTAssertEqual(orchestrator.engine?.run.phase, .paused)
    }

    /// Takılan tur terminal hata değildir: ilerlemesiz 20 dakika aynı eylemin
    /// yeniden kuyruklanmasıyla biter, faz korunur, tur sayacı yanar.
    func testStalledTurnRetriesInsteadOfFailing() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let startDate = Date()
        XCTAssertTrue(
            orchestrator.start(
                objective: "Hedef",
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectory: package,
                runners: runners(),
                bridge: session.bridge(),
                storeURL: temporaryURLs.last,
                now: startDate
            ))
        orchestrator.handleTurnFinished(now: startDate)
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
        XCTAssertEqual(session.submitted.map(\.mode), [.plan, .build])
        // Derleme turu koşuyor ama hiç ilerleme üretmiyor.
        session.busy = true
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds + 1))
        XCTAssertEqual(orchestrator.engine?.run.phase, .building, "Stall fazı değiştirmemeli")
        XCTAssertFalse(orchestrator.engine?.run.isTerminal ?? true, "Stall terminal olmamalı")
        XCTAssertEqual(orchestrator.engine?.run.iteration, 1, "Stall tur bütçesinden yemeli")
        // Aynı eylem yeniden kuyruklanır: tur bitince derleme yeniden gider.
        session.busy = false
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds + 2))
        XCTAssertEqual(session.submitted.map(\.mode), [.plan, .build, .build])
    }

    /// İlerleyen tur öldürülmez: kayan pencere ilerlemede tazelenir, 20 dakika
    /// duvar saati tek başına stall sayılmaz.
    func testProgressingTurnDoesNotStall() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let startDate = Date()
        XCTAssertTrue(
            orchestrator.start(
                objective: "Hedef",
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectory: package,
                runners: runners(),
                bridge: session.bridge(),
                storeURL: temporaryURLs.last,
                now: startDate
            ))
        orchestrator.handleTurnFinished(now: startDate)
        session.busy = true
        // 19. dakikada ilerleme: saat tazelenir.
        session.activities = 45
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds - 60))
        // Tazelenmeden 20 dakika sonra bile ilerleme varsa stall yok.
        session.activities = 46
        orchestrator.tick(now: startDate.addingTimeInterval(2 * GoalOrchestrator.turnTimeoutSeconds - 61))
        XCTAssertFalse(orchestrator.engine?.run.isTerminal ?? true)
        XCTAssertEqual(orchestrator.engine?.run.iteration, 0, "İlerleyen tur sayaç yakmamalı")
        XCTAssertEqual(orchestrator.engine?.run.phase, .building)
    }

    /// Kullanıcı bekleyen turda saat durur: soru/onay yanıtlanmadan hedef
    /// ölmez, stall sayacı işlemez.
    func testWaitingForUserPausesStallClock() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let startDate = Date()
        XCTAssertTrue(
            orchestrator.start(
                objective: "Hedef",
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectory: package,
                runners: runners(),
                bridge: session.bridge(),
                storeURL: temporaryURLs.last,
                now: startDate
            ))
        orchestrator.handleTurnFinished(now: startDate)
        session.busy = true
        session.waitingForUser = true
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds + 1))
        XCTAssertFalse(orchestrator.engine?.run.isTerminal ?? true, "Kullanıcı beklenirken hedef ölmemeli")
        XCTAssertEqual(orchestrator.engine?.run.iteration, 0)
        XCTAssertEqual(orchestrator.message, "Goal paused: waiting for your input.")
        // Kullanıcı yanıtladı, tur bitti: bekleme iletisi temizlenir, faz ilerler.
        session.waitingForUser = false
        session.busy = false
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds + 2))
        XCTAssertEqual(orchestrator.engine?.run.phase, .verifying)
    }

    /// Bütçe bitmişse stall yeniden denemez: koşu terminal hataya düşer.
    func testStalledTurnFailsWhenBudgetExhausted() {
        let orchestrator = GoalOrchestrator()
        let session = FakeGoalSession()
        let package = packageDirectory()
        let startDate = Date()
        let tight = GoalBudget(maxIterations: 1, maxDurationSeconds: 3_600, maxToolCalls: 300)
        XCTAssertTrue(
            orchestrator.start(
                objective: "Hedef",
                sessionID: UUID(),
                speedMode: .normal,
                mode: .build,
                workingDirectory: package,
                budget: tight,
                runners: runners(),
                bridge: session.bridge(),
                storeURL: temporaryURLs.last,
                now: startDate
            ))
        orchestrator.handleTurnFinished(now: startDate)
        session.busy = true
        // İlk stall: 1/1 sayaç yanar, retry kuyruklanır.
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds + 1))
        XCTAssertFalse(orchestrator.engine?.run.isTerminal ?? true)
        session.busy = false
        orchestrator.tick(now: startDate.addingTimeInterval(GoalOrchestrator.turnTimeoutSeconds + 2))
        // İkinci stall bütçeyi aşar: terminal.
        session.busy = true
        orchestrator.tick(now: startDate.addingTimeInterval(2 * (GoalOrchestrator.turnTimeoutSeconds + 2)))
        XCTAssertTrue(orchestrator.engine?.run.isTerminal ?? false)
        XCTAssertEqual(orchestrator.engine?.run.phase, .failed)
    }
}

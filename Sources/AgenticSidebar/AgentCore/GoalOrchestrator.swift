import Foundation
import Observation

/// Otonom hedef (`/goal`) döngüsünün orkestratörü: `GoalEngine` saf durum
/// makinesini oturum, koşucu ve depo ile çalışır hale getirir.
///
/// Döngü: plan turu (`.plan`) → uygulama turu (`.build`) → gerçek doğrulama
/// (`swift build` + `swift test`) → inceleme turu (`.review`) → kullanıcı
/// onayı (kritik/high sayısı) → yeşilse `done`, değilse düzeltme turu.
/// Dört kapı birden yeşil olmadan `done` imkânsızdır (`GoalVerifier`).
///
/// Güvenlik sınırları (tasarımın sigortası):
/// - Hedef, onay seviyesini asla gevşetemez; yıkıcı araç çağrıları yine
///   kullanıcıya sorulur (`PermissionApprovalCenter`'a dokunulmaz).
/// - Komutlar sabittir (`swift build`/`swift test`); kabuk ve kullanıcı
///   girdili komut yoktur. Çalışma dizini `Package.swift` şartıyla doğrulanır.
/// - Üçlü bütçe (tur + süre + araç çağrısı) aşımında döngü kendini durdurur.
/// - Durdurma her fazda çalışır; eski turun geç gelen bitişi `generation`
///   sayacıyla yok sayılır.
@MainActor
@Observable
final class GoalOrchestrator {
    /// Oturuma erişim: üretimde `AgentSessionService`, testlerde sahte.
    /// Kapanışlar `@MainActor` çalışır; `Sendable` değildir, orkartör de
    /// `@MainActor` olduğu için paylaşım güvenlidir.
    struct Bridge {
        var isBusy: @MainActor (UUID) -> Bool
        var activityCount: @MainActor (UUID) -> Int
        var submit: @MainActor (UUID, String, AgentMode, ResponseSpeedMode) -> PromptAcceptance
        /// Bitmiş turun hatası (`nil` = tur sağlıklı bitti). Sağlayıcı
        /// kesintisi (`transportFailure`, `streamInterrupted`, `rateLimited`,
        /// `contextLimitExceeded`…) yoksa faz ilerler; varsa koşu terminal
        /// hataya düşer — hatalı tur başarılı sanılmaz.
        var turnError: @MainActor (UUID) -> AgentSessionError?

        static var inert: Bridge {
            Bridge(
                isBusy: { _ in false },
                activityCount: { _ in 0 },
                submit: { _, _, _, _ in .rejected },
                turnError: { _ in nil }
            )
        }
    }

    /// Başlatılamayan hedefin isteği: ret görünür kalsın diye taşınır.
    /// Besteci taslağı korur (`ComposerView` yalnız kabulde temizler), panel
    /// hatayı + hedefi + klasör seçip yeniden denemeyi gösterir. Köprü ve
    /// koşucular da taşınır ki yeniden deneme aynı oturumda koşsun.
    struct FailedGoalRequest {
        var objective: String
        var sessionID: UUID
        var speedMode: ResponseSpeedMode
        var mode: AgentMode
        var budget: GoalBudget
        var runners: GoalRunners
        var bridge: Bridge
        var storeURL: URL?
    }

    /// Tur yokken yapılacak iş: fazdan türetmek yerine açıkça taşınır
    /// (`GoalPendingAction`; diske de yazılır). `nil` = tur uçuyor ya da
    /// eylem çoktan tüketildi.
    private var pendingAction: GoalPendingAction?

    /// Son reddedilen başlatma isteği (`nil` = ret yok ya da temizlendi).
    /// Panel bu varken hata kartı çizer; `dismiss` ve başarılı `start`
    /// temizler.
    private(set) var failedRequest: FailedGoalRequest?

    static let defaultBudget = GoalBudget(
        maxIterations: 5,
        maxDurationSeconds: 3_600,
        maxToolCalls: 300
    )
    /// Tek turun üst sınırı: aşan tur hedefi terminal hataya düşürür.
    static let turnTimeoutSeconds: TimeInterval = 1_200
    private static let pollIntervalSeconds: UInt64 = 1

    private(set) var engine: GoalEngine?
    private(set) var sessionID: UUID?
    private(set) var speedMode: ResponseSpeedMode = .normal
    private(set) var mode: AgentMode = .build
    private(set) var workingDirectoryPath: String = ""
    private(set) var awaitingReview = false
    private(set) var isVerifying = false
    private(set) var message: String?
    private(set) var lastReport: GoalVerificationReport?
    private(set) var resumableObjective: String?

    private var budget: GoalBudget = GoalOrchestrator.defaultBudget
    private var turnInFlight = false
    private var turnStartedAt: Date?
    private var baselineActivities = 0
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var verificationTask: Task<Void, Never>?
    private var storeURL: URL?
    private var runners: GoalRunners = .live()
    private var bridge: Bridge = .inert

    /// Anket görevinin yaşayıp yaşamadığı (testler için): terminal koşuda
    /// anket durmalı, yoksa uygulama ömrü boyunca saniyede bir uyanır.
    var isPolling: Bool {
        pollTask != nil
    }

    var isActive: Bool {
        engine.map { !$0.run.isTerminal } ?? false
    }

    /// Panel görünürlüğü: koşu varken (aktif, duraklatılmış ya da kapatılmayı
    /// bekleyen bitmiş), diskte devam edilebilir koşu varken veya
    /// reddedilmiş başlatma varken görünür; boş ipucu satırı yoktur
    /// (`GoalPanelView` koşulsuz dal çizmez). Ret görünmezse besteciden
    /// silinen metin ne sohbete ne panele düşerdi.
    var hasVisiblePanel: Bool {
        engine != nil || resumableObjective != nil || failedRequest != nil
    }

    // MARK: - Başlatma

    /// Yeni hedef başlatır. Bölme başına tek, uygulama başına tek koşu:
    /// depoda terminal-olmayan koşu varsa (başka bölme çalışıyor) reddedilir.
    @discardableResult
    func start(
        objective: String,
        sessionID: UUID,
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        workingDirectory: URL,
        budget: GoalBudget = GoalOrchestrator.defaultBudget,
        runners: GoalRunners = .live(),
        bridge: Bridge,
        storeURL: URL?,
        now: Date = Date()
    ) -> Bool {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Goal objective is empty."
            return false
        }
        // Ret isteği: boş hedefte yeniden denenecek bir şey yoktur, yalnız
        // ileti taşınır (bu yola besteciden ulaşılamaz; savunmadır).
        func refusal(_ text: String) -> Bool {
            message = text
            failedRequest = FailedGoalRequest(
                objective: trimmed,
                sessionID: sessionID,
                speedMode: speedMode,
                mode: mode,
                budget: budget,
                runners: runners,
                bridge: bridge,
                storeURL: storeURL
            )
            return false
        }
        guard !isActive else {
            message = "A goal is already running in this pane."
            return false
        }
        if let storeURL, let stored = GoalStore.load(from: storeURL), !stored.run.isTerminal {
            return refusal("Another pane is already running a goal (“\(stored.run.objective)”).")
        }
        guard GoalRunners.isSwiftPackage(at: workingDirectory) else {
            return refusal(
                "The goal directory has no Package.swift; choose a Swift package folder and retry."
            )
        }
        guard !bridge.isBusy(sessionID) else {
            return refusal("The conversation is busy; retry when the turn finishes — your text stayed in the composer.")
        }
        var next = GoalEngine(objective: trimmed, budget: budget, startedAt: now)
        let criterion = AcceptanceCriterion(id: UUID(), text: trimmed, isMet: false)
        guard next.begin(criteria: [criterion], date: now) else {
            return refusal("The goal could not be decomposed.")
        }
        self.engine = next
        self.budget = budget
        self.sessionID = sessionID
        self.speedMode = speedMode
        self.mode = mode
        self.workingDirectoryPath = workingDirectory.path
        self.runners = runners
        self.bridge = bridge
        self.storeURL = storeURL
        self.awaitingReview = false
        self.isVerifying = false
        self.lastReport = nil
        self.resumableObjective = nil
        self.message = nil
        self.failedRequest = nil
        self.pendingAction = .submitPlan
        self.turnInFlight = false
        generation += 1
        guard persist(now: now) else {
            // A goal that cannot be restored must never submit its first turn.
            engine = nil
            self.sessionID = nil
            self.storeURL = nil
            pendingAction = nil
            return false
        }
        ensurePolling()
        tick(now: now)
        return true
    }

    /// Kriter ekler (panelden): hedef "şu da olsun" diye büyütülebilir.
    func addCriterion(text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var engine else {
            return
        }
        let item = engine.addCriterion(text: trimmed, date: now)
        guard item != nil else {
            return
        }
        self.engine = engine
        persist(now: now)
    }

    func setCriterion(id: UUID, isMet: Bool, now: Date = Date()) {
        guard var engine else {
            return
        }
        guard engine.setCriterion(id: id, isMet: isMet, date: now) else {
            return
        }
        self.engine = engine
        persist(now: now)
    }

    /// Doğrulamanın koşacağı dizini değiştirir (bir sonraki adımdan geçerli).
    /// `Package.swift` barındırmayan dizin reddedilir, koşu etkilenmez.
    func updateWorkingDirectory(path: String, now: Date = Date()) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "The package directory is empty."
            return
        }
        guard GoalRunners.isSwiftPackage(at: URL(fileURLWithPath: trimmed)) else {
            message = "That directory has no Package.swift; keeping the previous one."
            return
        }
        workingDirectoryPath = trimmed
        message = nil
        persist(now: now)
    }

    // MARK: - Kontrol

    func pause(now: Date = Date()) {
        guard var engine, engine.pause(date: now) else {
            return
        }
        if isVerifying {
            verificationTask?.cancel()
            verificationTask = nil
            isVerifying = false
            pendingAction = .verify
        }
        self.engine = engine
        message = "Goal paused; the running turn (if any) finishes harmlessly."
        persist(now: now)
    }

    func resume(now: Date = Date()) {
        guard var engine, engine.resume(date: now) else {
            return
        }
        self.engine = engine
        message = nil
        if pendingAction == nil, !turnInFlight, !awaitingReview {
            // Duraklatmada uçan turun eylemi diske yazılamamıştı; fazdan
            // güvenli varsayımla devam edilir (yanlış tur yok, en kötü
            // halde bir tur tekrarlanır).
            pendingAction = Self.defaultAction(for: engine.run.phase)
        }
        persist(now: now)
        tick(now: now)
    }

    /// Döngüyü durdurur: bekleyen iş düşer, geç gelen tur bitişi yok sayılır.
    /// Devam eden ajan turu biterse çıktısı hedefe yazılmaz (zararsız biter).
    func stop(now: Date = Date()) {
        guard var engine, engine.stop(date: now) else {
            return
        }
        generation += 1
        verificationTask?.cancel()
        verificationTask = nil
        turnInFlight = false
        pendingAction = nil
        awaitingReview = false
        isVerifying = false
        pollTask?.cancel()
        pollTask = nil
        self.engine = engine
        message = "Goal stopped by user."
        persist(now: now)
    }

    /// Bitmiş/hatalı koşuyu ve reddedilmiş başlatmayı panelden kaldırır;
    /// terminal kaydı diskten silinir.
    func dismiss() {
        let preserveLastSnapshot = engine?.run.failureReason == .unrecoverable(detail: "goal state persistence failed")
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        verificationTask?.cancel()
        verificationTask = nil
        engine = nil
        sessionID = nil
        pendingAction = nil
        failedRequest = nil
        turnInFlight = false
        awaitingReview = false
        isVerifying = false
        lastReport = nil
        message = nil
        resumableObjective = nil
        if let storeURL, !preserveLastSnapshot {
            GoalStore.clear(storeURL)
        }
        storeURL = nil
    }

    /// Reddedilmiş başlatmayı temizler (koşuya dokunmaz): hata kartı
    /// kapanır. Koşu varken çağrılırsa koşunun iletisi korunur.
    func clearFailure() {
        guard engine == nil else {
            return
        }
        failedRequest = nil
        message = nil
    }

    /// Reddedilen isteği verilen dizinle yeniden dener: aynı hedef, oturum,
    /// kip, bütçe ve köprüyle `start` baştan koşar. Başarıda ret temizlenir,
    /// yeni rette kart güncel iletiyle kalır. Ret yoksa `false` döner.
    @discardableResult
    func retryFailedGoal(in directory: URL, now: Date = Date()) -> Bool {
        guard let request = failedRequest else {
            return false
        }
        return start(
            objective: request.objective,
            sessionID: request.sessionID,
            speedMode: request.speedMode,
            mode: request.mode,
            workingDirectory: directory,
            budget: request.budget,
            runners: request.runners,
            bridge: request.bridge,
            storeURL: request.storeURL,
            now: now
        )
    }

    /// İnceleme turu bitti, kullanıcı bulgu sayısını onaylar. Tüm kriterler
    /// işaretlenmeden `done` kapısı açılmaz: onay, kabulün ta kendisidir.
    func confirmReview(findings: Int, now: Date = Date()) {
        guard var engine, awaitingReview else {
            return
        }
        guard engine.run.unmetCriteriaCount == 0 else {
            message = "Mark every acceptance criterion before confirming the review."
            return
        }
        let reasons = Self.fixReasons(
            buildSucceeded: lastReport?.buildSucceeded ?? false,
            testsSucceeded: lastReport?.testsSucceeded ?? false,
            criticalOrHighFindings: findings,
            unmetCriteria: 0
        )
        awaitingReview = false
        guard engine.didFinishReview(criticalOrHighFindings: findings, date: now) else {
            return
        }
        if engine.run.phase == .done {
            message = "Goal done: all gates are green."
        } else {
            pendingAction = .submitFix(reasons: reasons)
            message = nil
        }
        self.engine = engine
        persist(now: now)
        tick(now: now)
    }

    // MARK: - Devam etme

    /// Diskteki koşuyu panele taşır (otomatik başlamaz).
    func noticeStoredRun(storeURL: URL, runners: GoalRunners = .live(), bridge: Bridge) {
        guard engine == nil, !isActive else {
            return
        }
        guard let stored = GoalStore.load(from: storeURL), !stored.run.isTerminal else {
            return
        }
        self.storeURL = storeURL
        self.runners = runners
        self.bridge = bridge
        resumableObjective = stored.run.objective
    }

    /// Kullanıcı "Resume" deyince motoru kurar. Oturum meşgulse devam eden
    /// tur evlat edinilir (çift gönderim olmaz); faz güvenli noktaya
    /// indirgenmiştir (`GoalStore.resumableRun`).
    func resumeStoredRun(now: Date = Date()) {
        guard let storeURL, engine == nil else {
            return
        }
        guard let stored = GoalStore.load(from: storeURL) else {
            // A damaged or newer-version run must remain recoverable rather
            // than being removed just because the resume action was attempted.
            resumableObjective = nil
            message = "The stored goal could not be read; its file was preserved for recovery."
            return
        }
        guard let resumed = GoalStore.resumableRun(from: stored, now: now) else {
            GoalStore.clear(storeURL)
            resumableObjective = nil
            return
        }
        var engine = GoalEngine(restoring: resumed.run, budget: resumed.budget)
        // `verifying`/`reviewing`/`fixing` ortasında kapanmışsa faz `building`e
        // indirgenmiştir; derleme turu kapanıştan önce bitmişti, o yüzden motor
        // kapıdan geçirilip doğrudan doğrulamaya alınır.
        let demoted = engine.run.phase == .building && stored.run.phase != .building
        if demoted {
            _ = engine.didFinishBuild(date: now)
            pendingAction = .verify
        } else if let action = resumed.pendingAction {
            pendingAction = action
        } else {
            // Tur uçuyordu, eylemi diske yazılamadı: fazdan güvenli varsayım.
            pendingAction = Self.defaultAction(for: engine.run.phase)
        }
        self.engine = engine
        budget = resumed.budget
        sessionID = resumed.sessionID
        speedMode = resumed.speedMode
        mode = resumed.mode
        workingDirectoryPath = resumed.workingDirectoryPath
        awaitingReview = false
        isVerifying = false
        message = "Goal resumed."
        resumableObjective = nil
        if let sessionID, bridge.isBusy(sessionID) {
            turnInFlight = true
            turnStartedAt = now
            baselineActivities = bridge.activityCount(sessionID)
            pendingAction = nil
        } else {
            turnInFlight = false
            if pendingAction == nil {
                pendingAction = Self.defaultAction(for: engine.run.phase)
            }
        }
        generation += 1
        persist(now: now)
        ensurePolling()
        tick(now: now)
    }

    // MARK: - Döngü

    private func ensurePolling() {
        guard pollTask == nil else {
            return
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(GoalOrchestrator.pollIntervalSeconds))
                guard !Task.isCancelled else {
                    return
                }
                self?.tick()
            }
        }
    }

    /// Testler doğrudan çağırır; üretim anket görevinden gelir.
    func tick(now: Date = Date()) {
        guard var engine, !engine.run.isTerminal, engine.run.phase != .paused else {
            if engine?.run.isTerminal == true {
                pollTask?.cancel()
                pollTask = nil
            }
            return
        }
        guard let sessionID else {
            return
        }
        if engine.isOverBudget(now: now) {
            engine.fail(
                .budgetExceeded(detail: "budget exceeded"),
                message: "Budget exceeded, stopping",
                date: now
            )
            self.engine = engine
            message = "Goal stopped: budget exceeded."
            persist(now: now)
            return
        }
        self.engine = engine
        if turnInFlight {
            if !bridge.isBusy(sessionID) {
                handleTurnFinished(now: now)
            } else if let started = turnStartedAt, now.timeIntervalSince(started) > Self.turnTimeoutSeconds {
                turnInFlight = false
                pendingAction = nil
                var failed = engine
                failed.fail(
                    .unrecoverable(detail: "an agent turn timed out after 20 minutes"),
                    message: "Turn timed out, stopping",
                    date: now
                )
                self.engine = failed
                message = "Goal stopped: a turn timed out."
                persist(now: now)
            }
            return
        }
        guard !isVerifying, !awaitingReview, let action = pendingAction else {
            return
        }
        perform(action, now: now)
    }

    private func perform(_ action: GoalPendingAction, now: Date) {
        guard let sessionID, var engine else {
            return
        }
        switch action {
        case .submitPlan:
            submitTurn(
                text: Self.planText(objective: engine.run.objective),
                mode: .plan,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .submitBuild:
            submitTurn(
                text: Self.buildText(objective: engine.run.objective),
                mode: .build,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .submitFix(let reasons):
            submitTurn(
                text: Self.fixText(objective: engine.run.objective, reasons: reasons),
                mode: .build,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .submitReview:
            submitTurn(
                text: Self.reviewText(objective: engine.run.objective),
                mode: .review,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .verify:
            pendingAction = nil
            isVerifying = true
            self.engine = engine
            let token = generation
            let directory = URL(fileURLWithPath: workingDirectoryPath)
            let runners = runners
            verificationTask?.cancel()
            verificationTask = Task { [weak self] in
                let report = await runners.verify(packageDirectory: directory)
                guard !Task.isCancelled else {
                    return
                }
                self?.finishVerification(report, token: token)
            }
        }
    }

    private func submitTurn(
        text: String,
        mode turnMode: AgentMode,
        sessionID: UUID,
        engine: inout GoalEngine,
        now: Date
    ) {
        let acceptance = bridge.submit(sessionID, text, turnMode, speedMode)
        guard acceptance.wasAccepted else {
            engine.fail(
                .unrecoverable(detail: "the session rejected the goal prompt"),
                message: "Session rejected the prompt, stopping",
                date: now
            )
            self.engine = engine
            message = "Goal stopped: the session could not accept the prompt."
            persist(now: now)
            return
        }
        baselineActivities = bridge.activityCount(sessionID)
        turnStartedAt = now
        turnInFlight = true
        pendingAction = nil
        self.engine = engine
        persist(now: now)
    }

    /// Üretimde anket, testlerde doğrudan çağrılır.
    func handleTurnFinished(now: Date = Date()) {
        guard var engine, turnInFlight, let sessionID else {
            return
        }
        turnInFlight = false
        // Hatalı biten tur faz ilerletmez: sağlayıcı kesintisi, hız sınırı ya
        // da bağlam taşması yokmuş gibi devam etmek döngüyü yanlış zeminde
        // koşturur (boş planın derlemesi gibi) ve bütçeyi/belleği yakar.
        if let error = bridge.turnError(sessionID) {
            let phase = engine.run.phase
            engine.fail(
                .unrecoverable(detail: "the \(phase.rawValue) turn failed: \(error)"),
                message: "Turn failed, stopping",
                date: now
            )
            self.engine = engine
            message = "Goal stopped: the \(phase.rawValue) turn failed (\(error))."
            persist(now: now)
            return
        }
        let delta = bridge.activityCount(sessionID) - baselineActivities
        engine.addToolCalls(max(0, delta), date: now)
        if engine.run.isTerminal {
            self.engine = engine
            message = "Goal stopped: tool-call budget exceeded."
            persist(now: now)
            return
        }
        switch engine.run.phase {
        case .planning:
            if engine.didFinishPlan(date: now) {
                pendingAction = .submitBuild
            }
        case .building:
            if engine.didFinishBuild(date: now) {
                pendingAction = .verify
            }
        case .reviewing:
            awaitingReview = true
            message = "Review turn finished. Mark the criteria, enter open Critical/High findings (0 if none), and confirm."
        case .fixing:
            if engine.noteFix(date: now) {
                pendingAction = .verify
            }
        case .decomposing, .verifying, .paused, .done, .failed:
            break
        }
        self.engine = engine
        persist(now: now)
        tick(now: now)
    }

    private func finishVerification(_ report: GoalVerificationReport, token: Int) {
        let now = Date()
        guard token == generation else {
            return
        }
        verificationTask = nil
        guard var engine, !engine.run.isTerminal else {
            return
        }
        guard engine.run.phase == .verifying else {
            // Doğrulama duraklatma sırasında bitti: raporu düşürüp kilidi aç,
            // devamında güvenli varsayımla yeniden doğrula (saf okuma).
            isVerifying = false
            if pendingAction == nil {
                pendingAction = .verify
            }
            self.engine = engine
            persist(now: now)
            return
        }
        isVerifying = false
        lastReport = report
        if engine.didFinishVerification(
            buildSucceeded: report.buildSucceeded,
            testsSucceeded: report.testsSucceeded,
            date: now
        ) {
            pendingAction = .submitReview
        }
        self.engine = engine
        persist(now: now)
        tick(now: now)
    }

    // MARK: - Tur metinleri

    static func planText(objective: String) -> String {
        "Create a short step-by-step implementation plan for the following objective. Reply with the plan only; do not make any changes yet:\n\n\(objective)"
    }

    static func buildText(objective: String) -> String {
        "Implement the plan above now. Keep changes minimal and focused on the objective:\n\n\(objective)"
    }

    static func reviewText(objective: String) -> String {
        "Review the changes made for this objective. Reply with a list of issues found, each labeled Critical, High, Medium, or Low. If there are none, say so explicitly:\n\n\(objective)"
    }

    static func fixText(objective: String, reasons: [String]) -> String {
        "The previous attempt still has these open items:\n\(reasons.map { "- \($0)" }.joined(separator: "\n"))\nAddress them now with minimal changes:\n\n\(objective)"
    }

    private static func fixReasons(
        buildSucceeded: Bool,
        testsSucceeded: Bool,
        criticalOrHighFindings: Int,
        unmetCriteria: Int
    ) -> [String] {
        GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: buildSucceeded,
                testsSucceeded: testsSucceeded,
                criticalOrHighFindings: criticalOrHighFindings,
                unmetCriteria: unmetCriteria
            )
        ).reasons
    }

    // MARK: - Rapor

    /// Kopyalanabilir hedef raporu: amaç, kapılar, kriterler, doğrulama özeti
    /// ve son günlük satırları. Transkript taşınmaz.
    static func report(
        run: GoalRun,
        budget: GoalBudget,
        verification: GoalVerificationReport?
    ) -> String {
        var lines = [
            "# Goal Report",
            "",
            "- Objective: \(run.objective)",
            "- Phase: \(run.phase.rawValue)",
            "- Iterations: \(run.iteration)/\(budget.maxIterations)",
            "- Tool calls: \(run.toolCallCount)/\(budget.maxToolCalls)",
        ]
        if let reason = run.failureReason {
            lines.append("- Stopped: \(reason)")
        }
        lines.append("")
        lines.append("## Acceptance criteria")
        lines.append("")
        if run.criteria.isEmpty {
            lines.append("None.")
        } else {
            for item in run.criteria {
                lines.append("- [\(item.isMet ? "x" : " ")] \(item.text)")
            }
        }
        lines.append("")
        lines.append("## Verification")
        lines.append("")
        lines.append(verification?.summary ?? "Not run yet.")
        if let tail = verification?.tests?.outputTail ?? verification?.build.outputTail,
            !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let fence = DiagnosticsCenter.fence(for: tail)
            lines.append("")
            lines.append(fence)
            lines.append(tail)
            lines.append(fence)
        }
        lines.append("")
        lines.append("## Log (last 30)")
        lines.append("")
        for entry in run.log.suffix(30) {
            lines.append("- \(DiagnosticsCenter.plainDate(entry.date)) · \(entry.phase.rawValue) · \(entry.message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func currentReport() -> String? {
        guard let engine else {
            return nil
        }
        return Self.report(run: engine.run, budget: budget, verification: lastReport)
    }

    // MARK: - Kalıcılık

    @discardableResult
    private func persist(now: Date) -> Bool {
        guard let engine, let sessionID, let storeURL else {
            return true
        }
        // Terminal koşu diskte durmaz: hem "tek aktif hedef" kuralı yalnız
        // çalışanı sayar, hem de bitmiş kayıt bir sonraki başlatmayı
        // gölgelemez. Rapor bellekte yaşamaya devam eder.
        if engine.run.isTerminal {
            GoalStore.clear(storeURL)
            return true
        }
        let stored = GoalStoredRun(
            run: engine.run,
            budget: budget,
            sessionID: sessionID,
            speedMode: speedMode,
            mode: mode,
            workingDirectoryPath: workingDirectoryPath,
            pendingAction: pendingAction,
            updatedAt: now
        )
        do {
            try GoalStore.save(stored, to: storeURL)
            return true
        } catch {
            // The previous on-disk snapshot is still the only recoverable
            // state. Stop in memory without calling persist again: a terminal
            // save would delete that snapshot.
            if var failed = self.engine, !failed.run.isTerminal {
                failed.fail(
                    .unrecoverable(detail: "goal state persistence failed"),
                    message: "Goal stopped: state could not be saved",
                    date: now
                )
                self.engine = failed
            }
            generation += 1
            verificationTask?.cancel()
            verificationTask = nil
            turnInFlight = false
            turnStartedAt = nil
            pendingAction = nil
            awaitingReview = false
            isVerifying = false
            pollTask?.cancel()
            pollTask = nil
            message = "Goal could not be saved: \(error.localizedDescription). Automatic continuation stopped; previous snapshot preserved."
            return false
        }
    }

    /// Fazdan güvenli varsayım: yanlış tur asla gönderilmez, en kötü halde
    /// bir tur tekrarlanır (derleme tekrar koşar, doğrulama saf okumadır).
    static func defaultAction(for phase: GoalPhase) -> GoalPendingAction? {
        switch phase {
        case .decomposing, .planning:
            return .submitPlan
        case .building:
            return .submitBuild
        case .verifying:
            return .verify
        case .reviewing:
            return .submitReview
        case .fixing:
            // Düzeltme turu kaybolduysa işi doğrula: kod değişmediyse kapılar
            // kırmızı döner ve gerekçeli yeni düzeltme turu kurulur.
            return .verify
        case .paused, .done, .failed:
            return nil
        }
    }
}

extension GoalGateDecision {
    fileprivate var reasons: [String] {
        switch self {
        case .done:
            return []
        case .fixing(let reasons):
            return reasons
        }
    }
}

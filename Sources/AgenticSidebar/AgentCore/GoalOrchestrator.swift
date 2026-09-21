import Foundation
import Observation

/// Otonom hedef (`/goal`) döngüsünün orkestratörü: `GoalEngine` saf durum
/// makinesini oturum, koşucu ve depo ile çalışır hale getirir.
///
/// Döngü: plan turu (`.plan`) → uygulama turu (`.build`) → gerçek doğrulama
/// (proje türüne göre `swift` ya da `xcodebuild` ile build + test) →
/// inceleme turu (`.review`) → kullanıcı onayı (kritik/high sayısı) → yeşilse `done`, değilse düzeltme turu.
/// Dört kapı birden yeşil olmadan `done` imkânsızdır (`GoalVerifier`).
///
/// Güvenlik sınırları (tasarımın sigortası):
/// - Hedef, onay seviyesini asla gevşetemez; yıkıcı araç çağrıları yine
///   kullanıcıya sorulur (`PermissionApprovalCenter`'a dokunulmaz).
/// - Komutlar sabittir (`swift build`/`swift test` ya da `xcodebuild`
///   build/test); kabuk ve kullanıcı girdili komut yoktur. Çalışma dizini
///   proje işareti (`Package.swift` ya da Xcode projesi) şartıyla doğrulanır.
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
        /// Son asistan yanıtı: otonom review kapısı buradan
        /// `CRITICAL_HIGH_COUNT` satırını okur. `nil` = yanıt yok ya da
        /// okunamadı; kapı o zaman bulguyu 0 sayar (eski davranış).
        /// Öntanımlı boştur, eski kurulumlar bozulmaz.
        var lastAssistantText: @MainActor (UUID) -> String? = { _ in nil }
        /// Zaman aşımında koşan turu durdurur. Eşzamansızdır ama köprü
        /// eşzamanlı tutulur (`Task` içinde ateşle-unut); öntanımlı boştur,
        /// o yüzden eski kurulumlar (test sahteleri dahil) bozulmaz.
        var cancel: @MainActor (UUID) -> Void = { _ in }
        /// Tur kullanıcıyı bekliyor mu (aracı sorusu ya da onay kuyruğu):
        /// `true` iken zaman aşımı saati işlemez — kullanıcı AFK diye hedef
        /// ölmez. Öntanımlı `false`, eski kurulumlar bozulmaz.
        var isWaitingForUser: @MainActor (UUID) -> Bool = { _ in false }

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
        /// Reddedildiği andaki dizin: otomatik başlatma aynı klasörde koşar,
        /// kullanıcıdan yeniden klasör istenmez.
        var workingDirectoryPath: String = ""
        /// Meşgul reddi kuyruktur, hata değil: tur bitince `tick` kendiliğinden
        /// başlatır, kullanıcı yeniden düğmeye basmaz.
        var autoStart: Bool = false
    }

    /// Tur yokken yapılacak iş: fazdan türetmek yerine açıkça taşınır
    /// (`GoalPendingAction`; diske de yazılır). `nil` = tur uçuyor ya da
    /// eylem çoktan tüketildi. Arayüzü ilgilendirmez (panel `engine`,
    /// `isVerifying`, `awaitingReview` okur), o yüzden saniyelik anket
    /// yazımları görünümü tetiklemez.
    @ObservationIgnored private var pendingAction: GoalPendingAction?

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
    /// Otonom devam (öntanımlı açık): `/goal` bir iş bitene kadar hiç
    /// durmaz; plan → build → verify → review → (gerekirse) fix döngüsü
    /// kullanıcı onayı beklemez. Kapalıysa eski manuel review kapısı çalışır
    /// (kriter + bulgu sayısı onayı). Codex-tarzı kesintisiz koşu için açık
    /// kalmalıdır.
    var autoContinue = true

    private var budget: GoalBudget = GoalOrchestrator.defaultBudget
    private var turnInFlight = false
    // Aşağıdaki defter sayaçları saniyelik anketin iç işidir; hiçbiri doğrudan
    // görünümde okunmaz. `@ObservationIgnored` olmadan her `tick` görünümü
    // baştan dizerdi (1Hz tam panel + transkript yerleşimi = donma).
    @ObservationIgnored private var turnStartedAt: Date?
    /// Son görülen ilerleme anı: tur saati kayan penceredir — araç çağrısı
    /// üreten tur 20 dakikada öldürülmez, ilerlemesiz takılan tur öldürülür.
    /// Kullanıcı beklemesi de ilerleme sayılır (saat durur).
    @ObservationIgnored private var turnLastProgressAt: Date?
    @ObservationIgnored private var lastSeenActivities = 0
    /// Zaman aşan turun aynen yeniden kuyruklanması için son gönderilen eylem
    /// saklanır (`fix` gerekçeleri dahil; fazdan türetme yanlış tur verirdi).
    @ObservationIgnored private var lastTurnAction: GoalPendingAction?
    @ObservationIgnored private var baselineActivities = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
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

    /// "Takılı goal" çakışma kartı mı: motorda koşu yok ama bu sohbetin
    /// dosyasında terminal-olmayan koşu duruyor. Hiçbir yerde bir şey
    /// koşmazken bu dosya her `/goal`u reddeder ve kartta çıkış yolu olmazsa
    /// kullanıcı kilitlenir; panel bu durumda "Discard stale goal" düğmesi çizer.
    /// Farklı sohbetlerin goal dosyaları ayrıdır, o yüzden bu kart yalnız aynı
    /// sohbetin yarım kalmış koşusunda görünür (eski tek-dosya sürümünden
    /// kalan miras ileti de tanınır).
    var showsStaleGoalConflict: Bool {
        guard engine == nil, let text = message else {
            return false
        }
        return text.contains("running goal")
            || text.contains("already running a goal")
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

    /// Yeni hedef başlatır. Bölme başına tek, oturum başına tek koşu:
    /// aynı sohbetin dosyasında terminal-olmayan koşu varsa reddedilir.
    /// Farklı sohbetler kendi dosyalarında eşzamanlı koşar (çoklu-goal serbest).
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
        func refusal(_ text: String, autoStart: Bool = false) -> Bool {
            message = text
            failedRequest = FailedGoalRequest(
                objective: trimmed,
                sessionID: sessionID,
                speedMode: speedMode,
                mode: mode,
                budget: budget,
                runners: runners,
                bridge: bridge,
                storeURL: storeURL,
                workingDirectoryPath: workingDirectory.path,
                autoStart: autoStart
            )
            // Kuyruk anketle yaşar: motor yokken `tick` çalışmazsa tur bitimi
            // hiç görülmez, hedef sonsuza dek beklerdi.
            if autoStart {
                ensurePolling()
            }
            return false
        }
        guard !isActive else {
            message = "A goal is already running in this pane."
            return false
        }
        if let storeURL, let stored = GoalStore.load(from: storeURL), !stored.run.isTerminal {
            return refusal("This conversation already has a running goal (“\(stored.run.objective)”).")
        }
        guard GoalRunners.supportedProject(at: workingDirectory) != nil else {
            return refusal(
                "The goal directory is not a SwiftPM package or Xcode project; choose a project folder and retry."
            )
        }
        guard !bridge.isBusy(sessionID) else {
            return refusal(
                "Goal queued — starts when this turn finishes.",
                autoStart: true
            )
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
        turnStartedAt = nil
        turnLastProgressAt = nil
        lastSeenActivities = 0
        lastTurnAction = nil
        generation += 1
        guard persist(now: now) else {
            // A goal that cannot be restored must never submit its first turn.
            // İstek panelde görünür kalsın: hata kartını ve yeniden deneme yolunu
            // yalnız `failedRequest` açar.
            engine = nil
            self.sessionID = nil
            self.storeURL = nil
            pendingAction = nil
            failedRequest = FailedGoalRequest(
                objective: trimmed,
                sessionID: sessionID,
                speedMode: speedMode,
                mode: mode,
                budget: budget,
                runners: runners,
                bridge: bridge,
                storeURL: storeURL,
                workingDirectoryPath: workingDirectory.path
            )
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
    /// Desteklenen proje barındırmayan dizin reddedilir, koşu etkilenmez.
    func updateWorkingDirectory(path: String, now: Date = Date()) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "The project directory is empty."
            return
        }
        guard GoalRunners.supportedProject(at: URL(fileURLWithPath: trimmed)) != nil else {
            message = "That directory is not a SwiftPM package or Xcode project; keeping the previous one."
            return
        }
        workingDirectoryPath = trimmed
        message = nil
        persist(now: now)
    }

    // MARK: - Kontrol

    func setAutoContinue(_ value: Bool) {
        autoContinue = value
    }

    /// Hedef metnini günceller ve ajanın güncel içerikle devam etmesini
    /// sağlar (Codex-tarzı): motorun hedefi değişir, sonraki tur metinleri
    /// güncel hedefle kurulur. Meşgulse yalnız hedef değişir (sıradaki tur
    /// zaten güncel metni kullanır); boşta ve bekleyen iş yoksa düzeltme
    /// turu kuyruklanır ki ajan hemen güncel içerikle çalışsın.
    func updateObjective(_ text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var engine, !engine.run.isTerminal else {
            return
        }
        guard engine.updateObjective(trimmed, date: now) else {
            return
        }
        self.engine = engine
        if !turnInFlight, !isVerifying, !awaitingReview, pendingAction == nil,
            engine.run.phase != .paused
        {
            pendingAction = .submitFix(reasons: ["Goal updated: \(trimmed)"])
        }
        persist(now: now)
        tick(now: now)
    }

    /// Oturumu kesmeden duraklatır: koşan ajan turu ve doğrulama kendi
    /// halinde biter, bitiş `resume` sonrasına ertelenir. `bridge.cancel`
    /// çağrılmaz, `turnInFlight` korunur; `tick` ve `handleTurnFinished`
    /// duraklatmada işlem yapmaz.
    func pause(now: Date = Date()) {
        guard var engine, engine.pause(date: now) else {
            return
        }
        self.engine = engine
        message = "Goal duraklatıldı. Devam edince kaldığı yerden sürer."
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

    /// Döngüyü durdurur: bekleyen iş düşer, koşan ajan turu hemen iptal
    /// edilir, geç gelen bitiş yok sayılır.
    func stop(now: Date = Date()) {
        guard var engine, engine.stop(date: now) else {
            return
        }
        generation += 1
        verificationTask?.cancel()
        verificationTask = nil
        if turnInFlight, let sessionID {
            bridge.cancel(sessionID)
        }
        turnInFlight = false
        turnStartedAt = nil
        turnLastProgressAt = nil
        lastTurnAction = nil
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
        lastTurnAction = nil
        turnStartedAt = nil
        turnLastProgressAt = nil
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

    /// Takılı kalmış koşuyu atar: motorda koşu yokken bu sohbetin dosyasında
    /// terminal-olmayan kayıt duruyorsa her `/goal` reddiyle ölür. Dosya
    /// (`storeURL` ya da reddedilen isteğin `storeURL`ü) silinir, kart kapanır;
    /// kullanıcı `/goal`u yeniden gönderebilir. Koşan hedefe dokunmaz
    /// (`engine != nil` iken etkisiz). Farklı sohbetlerin dosyalarına dokunmaz.
    func discardStaleStoredGoal() {
        guard engine == nil else {
            return
        }
        if let url = storeURL ?? failedRequest?.storeURL {
            GoalStore.clear(url)
        }
        storeURL = nil
        resumableObjective = nil
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

    /// Diskteki koşuyu panele taşır (otomatik başlamaz). Devam önerisi
    /// yalnız koşunun oturumu odaktayken çizilir, o yüzden `sessionID` de
    /// taşınır (`GoalPanelView` oturuma göre kapılar).
    func noticeStoredRun(storeURL: URL, runners: GoalRunners = .live(), bridge: Bridge) {
        guard engine == nil, !isActive else {
            return
        }
        guard let stored = GoalStore.load(from: storeURL), !stored.run.isTerminal else {
            return
        }
        // Oturum değişimi (tekli kipte sohbet geçişi): önceki sohbetin ret
        // kartı/iletisi yeni sohbete sızmamalıdır. Koşan hedef zaten yukarıda
        // korunur; burada motor yoktur, o yüzden sıfırlamak güvenlidir.
        if sessionID != stored.sessionID {
            failedRequest = nil
            message = nil
            resumableObjective = nil
        }
        self.storeURL = storeURL
        self.runners = runners
        self.bridge = bridge
        sessionID = stored.sessionID
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
            turnLastProgressAt = now
            baselineActivities = bridge.activityCount(sessionID)
            lastSeenActivities = baselineActivities
            // Uçan turun eylemi diske yazılamamıştı; fazdan güvenli varsayım
            // yeniden denemede kullanılır (yanlış tur yok, en kötü halde bir
            // tur tekrarlanır).
            lastTurnAction = pendingAction ?? Self.defaultAction(for: engine.run.phase)
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
        // Kuyruktaki hedef motor kurar: tur bitmişse aynı istekle `start`
        // baştan koşar; başarı reti temizler, meşgulde kuyruk sürer.
        if engine == nil {
            autoStartQueuedGoal(now: now)
        }
        guard var engine, !engine.run.isTerminal, engine.run.phase != .paused else {
            if engine?.run.isTerminal == true {
                pollTask?.cancel()
                pollTask = nil
            } else if engine == nil, failedRequest?.autoStart != true {
                // Yapacak iş yok: kuyruksuz ret ve motorsuz tur anketi
                // uygulama ömrü boyunca saniyede bir uyandırmazdı.
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
        // `engine` burada değişmedi (`guard var` kopyası, bütçe kapısı saf
        // okumadır): yazmak gözlemciyi boşuna tetiklerdi (1Hz görünüm
        // yenileme). Değişiklik olan yollarda ilgili yöntem zaten yazar.
        if turnInFlight {
            if !bridge.isBusy(sessionID) {
                handleTurnFinished(now: now)
            } else if bridge.isWaitingForUser(sessionID) {
                // Ajan kullanıcıya sordu ya da onay bekliyor: saat durur,
                // hedef ölmez. İlerleme saati tazelenir, panel bilgi verir.
                turnLastProgressAt = now
                lastSeenActivities = max(lastSeenActivities, bridge.activityCount(sessionID))
                if message != "Goal paused: waiting for your input." {
                    message = "Goal paused: waiting for your input."
                }
            } else {
                // Kayan pencere: araç çağrısı üreten tur öldürülmez; saat
                // yalnız ilerlemesiz takılmada dolar.
                let seen = bridge.activityCount(sessionID)
                if seen > lastSeenActivities {
                    lastSeenActivities = seen
                    turnLastProgressAt = now
                }
                let reference = turnLastProgressAt ?? turnStartedAt
                if let reference, now.timeIntervalSince(reference) > Self.turnTimeoutSeconds {
                    handleTurnStalled(now: now, sessionID: sessionID, engine: engine)
                }
            }
            return
        }
        guard !isVerifying, !awaitingReview, let action = pendingAction else {
            return
        }
        perform(action, now: now)
    }

    /// Kuyruktaki hedefi tur bitince kendiliğinden başlatır. Tur koşuyorsa
    /// sessizce beklenir; yeni ret kuyruk değilse (`autoStart` düştü) kart
    /// hata olarak kalır ve anket durur.
    private func autoStartQueuedGoal(now: Date) {
        guard let request = failedRequest, request.autoStart else {
            return
        }
        guard !request.bridge.isBusy(request.sessionID) else {
            return
        }
        _ = start(
            objective: request.objective,
            sessionID: request.sessionID,
            speedMode: request.speedMode,
            mode: request.mode,
            workingDirectory: URL(fileURLWithPath: request.workingDirectoryPath),
            budget: request.budget,
            runners: request.runners,
            bridge: request.bridge,
            storeURL: request.storeURL,
            now: now
        )
    }

    private func perform(_ action: GoalPendingAction, now: Date) {
        guard let sessionID, var engine else {
            return
        }
        switch action {
        case .submitPlan:
            lastTurnAction = action
            submitTurn(
                text: Self.planText(objective: engine.run.objective),
                mode: .plan,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .submitBuild:
            lastTurnAction = action
            submitTurn(
                text: Self.buildText(objective: engine.run.objective),
                mode: .build,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .submitFix(let reasons):
            lastTurnAction = action
            submitTurn(
                text: Self.fixText(objective: engine.run.objective, reasons: reasons),
                mode: .build,
                sessionID: sessionID,
                engine: &engine,
                now: now
            )
        case .submitReview:
            lastTurnAction = action
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
            // Görev `@MainActor` yalıtımlıdır: `finishVerification` aynı aktörde
            // koşar, `weak` yakalama da orkestratörü gereksiz yaşatmaz.
            verificationTask = Task { @MainActor [weak self] in
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
        turnLastProgressAt = now
        lastSeenActivities = baselineActivities
        turnInFlight = true
        pendingAction = nil
        self.engine = engine
        persist(now: now)
    }

    /// Takılan turun kurtarılması: oturumdaki koşu önce durdurulur, sonra
    /// tur sayacı yakılıp aynı eylem yeniden kuyruklanır. Bütçe bittiyse
    /// koşu terminal hataya düşer. İlerleyen tur buraya hiç ulaşmaz (kayan
    /// pencere), kullanıcı bekleyen tur da ulaşmaz (saat durur).
    private func handleTurnStalled(now: Date, sessionID: UUID, engine: GoalEngine) {
        var engine = engine
        turnInFlight = false
        turnStartedAt = nil
        turnLastProgressAt = nil
        // Zaman aşan tur oturumda koşmaya devam ederdi: önce köprüden
        // durdurulur, sonra aynı eylem yeniden denenir.
        bridge.cancel(sessionID)
        let retry = lastTurnAction ?? Self.defaultAction(for: engine.run.phase)
        if engine.noteTurnTimeout(date: now) {
            pendingAction = retry
            message = "Goal turn stalled with no progress for 20 minutes; retrying (attempt \(engine.run.iteration))."
        } else {
            pendingAction = nil
            lastTurnAction = nil
            message = "Goal stopped: budget exceeded."
        }
        self.engine = engine
        persist(now: now)
    }

    /// Üretimde anket, testlerde doğrudan çağrılır.
    /// Duraklatmada işlem yapmaz: koşan tur bitse bile faz ilerlemez,
    /// `turnInFlight` korunur; `resume` sonrası `tick` bitişi işler.
    func handleTurnFinished(now: Date = Date()) {
        guard var engine, turnInFlight, let sessionID else {
            return
        }
        guard engine.run.phase != .paused else {
            return
        }
        turnInFlight = false
        // Kullanıcı bekleme iletisi turun bitişiyle hükmünü yitirir.
        if message == "Goal paused: waiting for your input." {
            message = nil
        }
        // Hatalı biten tur faz ilerletmez: kalıcı hata (kimlik, bağlam taşması,
        // desteklenmeyen yetenek…) koşuyu terminal hataya düşürür; geçici
        // sağlayıcı kesintisi (ağ kopması, hız sınırı, akış kesintisi,
        // sağlayıcı yokluğu) aynı turun yeniden denenmesidir — tek bir
        // dalgalanma saatlik hedefi öldürmez. Yeniden deneme tur sayacını
        // yakar, bütçe biterse koşu `failed` olur.
        if let error = bridge.turnError(sessionID) {
            // unexpectedBackendResponse tur iş üretmişse geçicidir: arka uç
            // çalıştı (araç koştu) ama tur yine de düştü — tek satırlık akış
            // gürültüsü gibi bir hıçkırık, yanlış yapılandırma değil. Bütçe
            // korumalı tek deneme hakkı aynı yoldan gider. Sıfır araçla gelen
            // aynı hata kalıcıdır (bozuk model/kimlik), koşu durur.
            let producedWork = bridge.activityCount(sessionID) - baselineActivities > 0
            let retryAfterWork =
                error == .unexpectedBackendResponse && producedWork
            if Self.isRetryableTurnError(error) || retryAfterWork {
                let retry = lastTurnAction ?? Self.defaultAction(for: engine.run.phase)
                if engine.noteTransientTurnError(detail: "\(error)", date: now) {
                    pendingAction = retry
                    message = "Goal turn hit \(error), retrying (attempt \(engine.run.iteration))."
                    self.engine = engine
                    persist(now: now)
                    tick(now: now)
                } else {
                    pendingAction = nil
                    lastTurnAction = nil
                    self.engine = engine
                    message = "Goal stopped: budget exceeded."
                    persist(now: now)
                }
                return
            }
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
            if autoContinue {
                autoConfirmReview(engine: &engine, now: now)
            } else {
                awaitingReview = true
                message = "Review turn finished. Mark the criteria, enter open Critical/High findings (0 if none), and confirm."
            }
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

    /// Otonom review onayı: inceleme turu bitince kullanıcı beklemez.
    /// Review turu `.review` kipinde koşar, yani `AgentMode.review`
    /// (Alibaba Open Code Review) sistem talimatıyla; bu yöntem turun
    /// yanıtındaki `CRITICAL_HIGH_COUNT: N` satırını okuyup kapıya taşır.
    /// Doğrulama yeşilse kriterler otomatik karşılanır, kapılar
    /// değerlendirilir: hepsi yeşilse `done`, değilse gerekçeli düzeltme turu
    /// kuyruklanır. Döngü plan → build → verify → review → (fix) arasında
    /// kendi içinde kip değiştirerek istenen yapılana kadar durmaz.
    private func autoConfirmReview(engine: inout GoalEngine, now: Date) {
        let buildOK = lastReport?.buildSucceeded ?? false
        let testsOK = lastReport?.testsSucceeded ?? false
        if buildOK, testsOK {
            _ = engine.markAllCriteriaMet(date: now)
        }
        let findings: Int
        if let sessionID {
            findings = GoalReviewFindings.count(from: bridge.lastAssistantText(sessionID))
        } else {
            findings = 0
        }
        guard engine.didFinishReview(criticalOrHighFindings: findings, date: now) else {
            return
        }
        if engine.run.phase == .done {
            message = "Goal done: all gates are green."
        } else {
            let reasons = Self.fixReasons(
                buildSucceeded: buildOK,
                testsSucceeded: testsOK,
                criticalOrHighFindings: findings,
                unmetCriteria: engine.run.unmetCriteriaCount
            )
            pendingAction = .submitFix(reasons: reasons)
            message = nil
        }
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

    /// Bitirici mühendis planı: eksiksiz, doğrulanabilir, gerçekçi.
    static func planText(objective: String) -> String {
        "You are a senior finisher engineer. Create a complete step-by-step implementation plan for the following objective. Cover every missing, broken, and failing part — leave nothing vague. Map each acceptance criterion to concrete files and changes, list risks, and how the result will be verified (build + tests). Reply with the plan only; do not make any changes yet:\n\n\(objective)"
    }

    /// Bitirici mühendis derlemesi: yarım iş yok, kök neden düzelir.
    static func buildText(objective: String) -> String {
        "Implement the plan above now like a senior finisher engineer. Finish everything: no TODO, no placeholder, no stub, no half-done work. Fix root causes, not symptoms. Sweep all related bugs, missing validations, and error paths while keeping changes minimal and focused on the objective:\n\n\(objective)"
    }

    /// Review turu `AgentMode.review` (Alibaba Open Code Review standardı)
    /// ile aynı yapıyı kullanır: salt-okunur inceleme, şiddet gruplu
    /// bulgular, dosya:satır referansları ve makine-okunur sayaç satırı.
    /// Tur `.review` kipinde gönderildiği için sistem talimatı zaten bu
    /// standardı taşır; bu metin tur içi yönergeyi pekiştirir ve kapının
    /// okuyacağı `CRITICAL_HIGH_COUNT` satırını zorunlu kılar.
    static func reviewText(objective: String) -> String {
        "REVIEW MODE (Alibaba Open Code Review standard) — read-only review for this goal. STRICT READ-ONLY: do not create, edit, delete, or modify any files, and do not run state-changing commands. Inspect with read-only tools. Analyze for: 1) Correctness & logic bugs (boundary, empty, off-by-one), 2) Null/Optional safety, 3) Thread safety, race conditions & concurrency, 4) Security vulnerabilities (injection, XSS, insecure deserialization, credentials), 5) Performance bottlenecks, 6) Maintainability. Group findings by severity (Critical, High, Medium, Low) with exact file:line references. End your reply with exactly one machine-readable line: CRITICAL_HIGH_COUNT: <N> where N is Critical+High count (0 if none). If there are no issues, say so explicitly and still emit CRITICAL_HIGH_COUNT: 0.\n\nObjective:\n\n\(objective)"
    }

    /// Bitirici mühendis düzeltmesi: açık ne varsa silip süpürür.
    static func fixText(objective: String, reasons: [String]) -> String {
        "Finisher pass like a senior engineer — the previous attempt still has these open items:\n\(reasons.map { "- \($0)" }.joined(separator: "\n"))\nAddress ALL of them now with root-cause fixes. Sweep every related problem, missing validation, error path, and concurrency/security issue (Alibaba review categories). Leave the repo green: no TODO, no placeholder, no half work. Then stop — verification will run build + tests.\n\nObjective:\n\n\(objective)"
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
        // Terminal koşu diskte durmaz: hem "oturum başına tek koşu" kuralı yalnız
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
            turnLastProgressAt = nil
            lastTurnAction = nil
            pendingAction = nil
            awaitingReview = false
            isVerifying = false
            pollTask?.cancel()
            pollTask = nil
            message = "Goal could not be saved: \(error.localizedDescription). Automatic continuation stopped; previous snapshot preserved."
            return false
        }
    }

    /// Geçici sağlayıcı kesintisi mi: ağ kopması, hız sınırı, akış kesintisi
    /// ve sağlayıcı yokluğu aynı turun yeniden denenmesidir; kimlik,
    /// bağlam taşması ve çalıştırılamaz arka uç kalıcıdır, hedefi durdurur.
    /// Saf fonksiyondur.
    static func isRetryableTurnError(_ error: AgentSessionError) -> Bool {
        switch error {
        case .transportFailure, .streamInterrupted, .rateLimited, .providerUnavailable:
            return true
        case .missingCredential, .authenticationFailure, .backendExecutableUnavailable,
            .backendStartupFailure, .unsupportedCapability, .contextLimitExceeded,
            .unexpectedBackendResponse:
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

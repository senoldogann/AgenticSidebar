import Foundation

/// Hedef koşusunun değer-tipi fotoğrafı: faz, kriterler, sayaçlar ve günlük.
struct GoalRun: Equatable, Sendable, Codable {
    let id: UUID
    let objective: String
    var criteria: [AcceptanceCriterion]
    var phase: GoalPhase
    var iteration: Int
    let startedAt: Date
    var toolCallCount: Int
    var log: [GoalLogEntry]
    var failureReason: GoalFailureReason?

    var isTerminal: Bool {
        phase == .done || phase == .failed
    }

    var unmetCriteriaCount: Int {
        criteria.filter { !$0.isMet }.count
    }
}

/// Otonom döngünün saf durum makinesi: bağımlılığı yoktur, G/Ç yapmaz,
/// yalnızca değer üretir. Yanlış fazdaki çağrı `false` dönüp yok sayılır.
/// Bütçe zamanlayıcısı yoktur; çalıştıran taraf `isOverBudget(now:)` sonucunu
/// periyodik yoklar (saf makine kendi kendine uyanamaz).
struct GoalEngine: Sendable {
    private(set) var run: GoalRun
    let budget: GoalBudget
    private var lastBuildSucceeded: Bool?
    private var lastTestsSucceeded: Bool?
    private var lastCriticalHigh: Int?

    /// Duraklatmadan önceki faz: devam edince buraya dönülür.
    private var phaseBeforePause: GoalPhase?
    /// Duraklatmada geçen toplam süre: süre bütçesi duvar saatinden düşer,
    /// yoksa duraklatmak bütçeyi yakmaya devam ederdi.
    private var pausedTotal: TimeInterval = 0
    private var pauseBegan: Date?

    init(objective: String, budget: GoalBudget, startedAt: Date) {
        self.run = GoalRun(
            id: UUID(),
            objective: objective,
            criteria: [],
            phase: .decomposing,
            iteration: 0,
            startedAt: startedAt,
            toolCallCount: 0,
            log: [GoalLogEntry(date: startedAt, phase: .decomposing, message: "Goal started")],
            failureReason: nil
        )
        self.budget = budget
    }

    /// Kalıcı depodan devam: motor geçici kapı anlık görüntülerini
    /// (`verifying`/`reviewing` arası değerler) kaybeder, o yüzden çağrı
    /// tarafı (`GoalStore.resumableRun`) fazı güvenli bir noktaya
    /// indirgemiş olur. Bütçe ve sayaçlar aynen korunur.
    init(restoring run: GoalRun, budget: GoalBudget) {
        self.run = run
        self.budget = budget
    }

    /// Ayrıştırma bitti: kriterler planlamaya taşınır. Boş liste ayrıştırma
    /// başarısızlığıdır, koşu terminal hataya düşer.
    @discardableResult
    mutating func begin(criteria: [AcceptanceCriterion], date: Date) -> Bool {
        guard run.phase == .decomposing else {
            return false
        }
        if criteria.isEmpty {
            run.phase = .failed
            run.failureReason = .unrecoverable(detail: "decomposition produced no acceptance criteria")
            record(date: date, phase: .failed, message: "Decomposition produced no criteria")
            return true
        }
        run.criteria = criteria
        run.phase = .planning
        record(date: date, phase: .planning, message: "Planned \(criteria.count) acceptance criteria")
        return true
    }

    @discardableResult
    mutating func didFinishPlan(date: Date) -> Bool {
        guard run.phase == .planning else {
            return false
        }
        run.phase = .building
        record(date: date, phase: .building, message: "Plan ready, building")
        return true
    }

    @discardableResult
    mutating func didFinishBuild(date: Date) -> Bool {
        guard run.phase == .building else {
            return false
        }
        run.phase = .verifying
        record(date: date, phase: .verifying, message: "Build finished, verifying")
        return true
    }

    @discardableResult
    mutating func didFinishVerification(buildSucceeded: Bool, testsSucceeded: Bool, date: Date) -> Bool {
        guard run.phase == .verifying else {
            return false
        }
        lastBuildSucceeded = buildSucceeded
        lastTestsSucceeded = testsSucceeded
        run.phase = .reviewing
        record(date: date, phase: .reviewing, message: "Verification recorded, reviewing")
        return true
    }

    /// Review bitti: kapılar değerlendirilir. Hepsi yeşilse `done`, değilse
    /// bütçe yetiyorsa `fixing` (tur sayacı artar), yetmiyorsa `failed`.
    @discardableResult
    mutating func didFinishReview(criticalOrHighFindings: Int, date: Date) -> Bool {
        guard run.phase == .reviewing else {
            return false
        }
        lastCriticalHigh = criticalOrHighFindings
        let decision = GoalVerifier.evaluate(
            GoalGateInput(
                buildSucceeded: lastBuildSucceeded ?? false,
                testsSucceeded: lastTestsSucceeded ?? false,
                criticalOrHighFindings: criticalOrHighFindings,
                unmetCriteria: run.unmetCriteriaCount
            ))
        switch decision {
        case .done:
            run.phase = .done
            record(date: date, phase: .done, message: "All gates green, goal done")
        case .fixing(let reasons):
            run.iteration += 1
            if isOverBudget(now: date) {
                run.phase = .failed
                run.failureReason = .budgetExceeded(detail: "budget exceeded after \(run.iteration) iterations")
                record(date: date, phase: .failed, message: "Budget exceeded, stopping")
            } else {
                run.phase = .fixing
                record(date: date, phase: .fixing, message: "Fixing: \(reasons.joined(separator: "; "))")
            }
        }
        return true
    }

    /// Düzeltme turu bitti, yeniden derlemeye dönülür.
    @discardableResult
    mutating func noteFix(date: Date) -> Bool {
        guard run.phase == .fixing else {
            return false
        }
        run.phase = .building
        record(date: date, phase: .building, message: "Fix applied, rebuilding (iteration \(run.iteration))")
        return true
    }

    /// Kriter bayrağını günceller; terminal koşuda işlem yapmaz.
    @discardableResult
    mutating func setCriterion(id: UUID, isMet: Bool, date: Date) -> Bool {
        guard !run.isTerminal else {
            return false
        }
        guard let index = run.criteria.firstIndex(where: { $0.id == id }) else {
            return false
        }
        run.criteria[index].isMet = isMet
        record(date: date, phase: run.phase, message: "Criterion '\(run.criteria[index].text)' met=\(isMet)")
        return true
    }

    /// Yeni kabul kriteri ekler (hedef panelden büyütülebilir); terminal
    /// koşuda işlem yapmaz.
    @discardableResult
    mutating func addCriterion(text: String, date: Date) -> AcceptanceCriterion? {
        guard !run.isTerminal else {
            return nil
        }
        let item = AcceptanceCriterion(id: UUID(), text: text, isMet: false)
        run.criteria.append(item)
        record(date: date, phase: run.phase, message: "Criterion added: '\(text)'")
        return item
    }

    /// Araç çağrılarını sayar; bütçe aşılırsa koşuyu durdurur. Sıfır ve
    /// negatif değerler yok sayılır: sayaç asla geri sarılamaz.
    mutating func addToolCalls(_ count: Int, date: Date) {
        guard !run.isTerminal, count > 0 else {
            return
        }
        run.toolCallCount += count
        if isOverBudget(now: date) {
            run.phase = .failed
            run.failureReason = .budgetExceeded(detail: "tool call budget exceeded at \(run.toolCallCount) calls")
            record(date: date, phase: .failed, message: "Tool call budget exceeded, stopping")
        }
    }

    /// Bütçe sorgusu: çalıştıran taraf periyodik çağırır. Duraklatmada geçen
    /// süre düşülür (devam eden duraklatma dahil).
    func isOverBudget(now: Date) -> Bool {
        return budget.isExceeded(
            iterations: run.iteration,
            elapsedSeconds: elapsedSeconds(now: now),
            toolCalls: run.toolCallCount
        )
    }

    /// Koşunun aktif süresi (saniye): duvar saatinden duraklatmada geçen
    /// toplam düşülür, devam eden duraklatma dahil. Bitmiş koşuda sayaç
    /// terminal ana donar (son günlük satırının anı), yoksa paneldeki süre
    /// bitişten sonra da işlemeye devam ederdi.
    func elapsedSeconds(now: Date) -> TimeInterval {
        let end: Date
        if run.isTerminal, let last = run.log.last?.date, last < now {
            end = last
        } else {
            end = now
        }
        var elapsed = end.timeIntervalSince(run.startedAt) - pausedTotal
        if let began = pauseBegan {
            elapsed -= end.timeIntervalSince(began)
        }
        return max(0, elapsed)
    }

    @discardableResult
    mutating func pause(date: Date) -> Bool {
        guard !run.isTerminal, run.phase != .paused else {
            return false
        }
        phaseBeforePause = run.phase
        pauseBegan = date
        run.phase = .paused
        record(date: date, phase: .paused, message: "Paused")
        return true
    }

    @discardableResult
    mutating func resume(date: Date) -> Bool {
        guard run.phase == .paused else {
            return false
        }
        if let began = pauseBegan {
            pausedTotal += date.timeIntervalSince(began)
        }
        pauseBegan = nil
        run.phase = phaseBeforePause ?? .planning
        phaseBeforePause = nil
        record(date: date, phase: run.phase, message: "Resumed")
        return true
    }

    @discardableResult
    mutating func stop(date: Date) -> Bool {
        guard !run.isTerminal else {
            return false
        }
        pauseBegan = nil
        run.phase = .failed
        run.failureReason = .cancelledByUser
        record(date: date, phase: .failed, message: "Stopped by user")
        return true
    }

    /// Terminal hata: bütçe aşımı, tur zaman aşımı, reddedilen gönderim gibi
    /// motorun kendi geçişlerinin kapsamadığı durmalar. Sebep ve günlük
    /// satırıyla kapanır; terminal koşuda işlem yapmaz.
    mutating func fail(_ reason: GoalFailureReason, message: String, date: Date) {
        guard !run.isTerminal else {
            return
        }
        pauseBegan = nil
        run.phase = .failed
        run.failureReason = reason
        record(date: date, phase: .failed, message: message)
    }

    // MARK: - Günlük

    private mutating func record(date: Date, phase: GoalPhase, message: String) {
        run.log.append(GoalLogEntry(date: date, phase: phase, message: message))
    }
}

import Foundation

/// Otonom hedef (`/goal`) döngüsünün fazları.
///
/// Akış: `decomposing` → `planning` → `building` → `verifying` → `reviewing` →
/// bulgu varsa `fixing` (→ `building`), yoksa `done`. `paused` her fazdan
/// girilip çıkılabilen bekleme durumudur; `failed` terminaldir.
enum GoalPhase: String, Equatable, Sendable, Codable {
    case decomposing
    case planning
    case building
    case verifying
    case reviewing
    case fixing
    case paused
    case done
    case failed
}

/// Tek kabul kriteri: hedefin bölünmüş, doğrulanabilir parçası.
struct AcceptanceCriterion: Equatable, Sendable, Codable {
    let id: UUID
    let text: String
    var isMet: Bool
}

/// Döngünün kendini durdurma kapakları: sonsuz döngü ve maliyet patlaması
/// bu üç sınırla imkânsız hale gelir.
struct GoalBudget: Equatable, Sendable, Codable {
    /// İzin verilen en fazla düzeltme turu.
    let maxIterations: Int
    /// Saniye cinsinden en fazla toplam süre.
    let maxDurationSeconds: TimeInterval
    /// En fazla araç çağrısı.
    let maxToolCalls: Int

    /// Üç sınırdan biri aşılırsa `true` döner.
    func isExceeded(iterations: Int, elapsedSeconds: TimeInterval, toolCalls: Int) -> Bool {
        iterations > maxIterations
            || elapsedSeconds > maxDurationSeconds
            || toolCalls > maxToolCalls
    }
}

/// Hedefin neden durduğunu açıklayan terminal nedeni.
enum GoalFailureReason: Equatable, Sendable, Codable {
    case budgetExceeded(detail: String)
    case cancelledByUser
    case unrecoverable(detail: String)
}

/// Faz geçişlerinin denetim izindeki tek satırı.
struct GoalLogEntry: Equatable, Sendable, Codable {
    let date: Date
    let phase: GoalPhase
    let message: String
}

/// Tur yokken yapılacak iş: fazdan türetmek yerine açıkça taşınır, yoksa
/// yeniden başlatma sonrası "derleme mi, doğrulama mı" belirsizliği yanlış
/// tura yol açardı. Diske de yazılır (`GoalStoredRun`), o yüzden `Codable`.
enum GoalPendingAction: Equatable, Sendable, Codable {
    case submitPlan
    case submitBuild
    case verify
    case submitReview
    case submitFix(reasons: [String])
}

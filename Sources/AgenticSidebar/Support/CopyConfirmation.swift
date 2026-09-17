import AppKit
import Observation

/// Panoya kopyalamanın iki satırlık tekrarı için tek karşılık.
///
/// Altı ayrı noktada elle kurulan `clearContents → setString → isCopied → sleep`
/// sırası burada bir kez yaşar: bayrak ve geri-sayım bu sınıfta, pano yazımı
/// `Pasteboard.copy(_:)` içinde.
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Kopyala-bildir bayrağını taşıyan küçük gözlemlenebilir durum.
///
/// İkinci bir kopyalama birincinin geri-sayımını iptal eder, böylece bayrak
/// erken sönmez. Süre varsayılanı mevcut ekranlardaki 1,5 saniyedir.
@MainActor
@Observable
final class CopyConfirmation {
    private(set) var isCopied = false
    private var resetTask: Task<Void, Never>?

    func copy(_ text: String, revertAfter: Duration = .seconds(1.5)) {
        Pasteboard.copy(text)
        isCopied = true
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: revertAfter)
            guard !Task.isCancelled else {
                return
            }
            self?.isCopied = false
        }
    }
}

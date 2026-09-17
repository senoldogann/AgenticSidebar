import Foundation

/// Bir sohbetin "buradan dallan" (fork) planı.
///
/// Fork sunucu tarafında bir checkpoint değildir: kaynak oturumun seçilen
/// mesaja kadar olan ön ekini yeni bir yerel oturuma kopyalar. İlk gönderimde
/// provider runtime zaten `state.messages` içeriğini history preamble olarak
/// tekrar oynattığı için backend bu önek üzerinden devam eder. Tool çıktıları
/// yeniden çalıştırılmaz, yalnızca metin olarak taşınır.
struct SessionForkPlan: Equatable, Sendable {
    /// Kaynak oturumdan taşınan mesaj ön eki (dönüm noktası dahil).
    let messages: [ChatMessage]
    /// Çapası ön ekin içinde kalan aktivite grupları.
    let activityGroups: [AgentTurnActivityGroup]
    /// Kaynak başlıktan türetilen dal başlığı.
    let title: String
}

enum SessionFork {
    /// Dal başlığı için kullanılan son ek.
    nonisolated static let branchSuffix = " (branch)"

    /// Verilen dönüm noktasına kadar olan fork planını kurar.
    ///
    /// - Returns: Dönüm noktası kaynak mesajlarda yoksa `nil`.
    static func plan(
        sourceMessages: [ChatMessage],
        sourceActivityGroups: [AgentTurnActivityGroup],
        sourceAutomaticTitle: String,
        sourceCustomTitle: String?,
        throughMessageID: UUID
    ) -> SessionForkPlan? {
        guard let anchorIndex = sourceMessages.firstIndex(where: { $0.id == throughMessageID }) else {
            return nil
        }
        let prefix = Array(sourceMessages[...anchorIndex])
        let prefixIDs = Set(prefix.map(\.id))
        let groups = sourceActivityGroups.filter { prefixIDs.contains($0.anchorMessageID) }
        return SessionForkPlan(
            messages: prefix,
            activityGroups: groups,
            title: branchedTitle(customTitle: sourceCustomTitle, automaticTitle: sourceAutomaticTitle)
        )
    }

    /// Boş/boşluk başlıklar otomatiğe düşer; son ek zaten varsa tekrar eklenmez.
    static func branchedTitle(customTitle: String?, automaticTitle: String) -> String {
        let base: String
        if let customTitle {
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            base = trimmed.isEmpty ? automaticTitle : trimmed
        } else {
            base = automaticTitle
        }
        if base.hasSuffix(branchSuffix) {
            return base
        }
        return base + branchSuffix
    }
}

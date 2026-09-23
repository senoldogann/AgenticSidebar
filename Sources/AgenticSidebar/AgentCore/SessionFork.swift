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
    /// - Parameter isSourceBusy: Kaynak tur çalışıyorsa sondaki yarım asistan
    ///   mesajı geçmişe tam metinmiş gibi taşınmasın diye önekten çıkarılır.
    /// - Returns: Dönüm noktası kaynak mesajlarda yoksa `nil`.
    ///
    /// Kimlikler yeniden üretilir: dal kaynakla aynı mesaj/aktivite kimliklerini
    /// taşırsa `TimelineCollapseStore` gibi oturuma değil kimliğe bakan depolar
    /// iki sohbetin durumunu birbirine karıştırır.
    static func plan(
        sourceMessages: [ChatMessage],
        sourceActivityGroups: [AgentTurnActivityGroup],
        sourceAutomaticTitle: String,
        sourceCustomTitle: String?,
        throughMessageID: UUID,
        isSourceBusy: Bool = false
    ) -> SessionForkPlan? {
        guard let anchorIndex = sourceMessages.firstIndex(where: { $0.id == throughMessageID }) else {
            return nil
        }
        var prefix = Array(sourceMessages[...anchorIndex])
        if isSourceBusy, prefix.count > 1, anchorIndex == sourceMessages.count - 1, prefix.last?.role == .assistant {
            prefix.removeLast()
        }
        var idMap: [UUID: UUID] = [:]
        let messages = prefix.map { message -> ChatMessage in
            let fresh = UUID()
            idMap[message.id] = fresh
            return message.withID(fresh)
        }
        let prefixIDs = Set(messages.map(\.id))
        // Grup turn kimlikleri de yenilenir: bayat `turnID` dal oturumunda hiç
        // koşmamış bir tura aittir, canlı tur eşleşmelerini şaşırtır.
        var turnMap: [UUID: UUID] = [:]
        let groups =
            sourceActivityGroups
            .filter { group in
                guard let mapped = idMap[group.anchorMessageID] else {
                    return false
                }
                return prefixIDs.contains(mapped)
            }
            .map { group -> AgentTurnActivityGroup in
                let freshTurnID: UUID?
                if let sourceTurnID = group.turnID {
                    if let mapped = turnMap[sourceTurnID] {
                        freshTurnID = mapped
                    } else {
                        let fresh = UUID()
                        turnMap[sourceTurnID] = fresh
                        freshTurnID = fresh
                    }
                } else {
                    freshTurnID = nil
                }
                return AgentTurnActivityGroup(
                    id: UUID(),
                    anchorMessageID: idMap[group.anchorMessageID] ?? group.anchorMessageID,
                    activities: group.activities.map { activity in
                        AgentActivity(
                            id: ProviderActivityID(UUID().uuidString),
                            kind: activity.kind,
                            phase: activity.phase,
                            title: activity.title,
                            detail: activity.detail,
                            output: activity.output,
                            diff: activity.diff,
                            startedAt: activity.startedAt,
                            completedAt: activity.completedAt
                        )
                    },
                    turnID: freshTurnID
                )
            }
        return SessionForkPlan(
            messages: messages,
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
        guard !base.isEmpty else {
            return "New session" + branchSuffix
        }
        return base + branchSuffix
    }
}

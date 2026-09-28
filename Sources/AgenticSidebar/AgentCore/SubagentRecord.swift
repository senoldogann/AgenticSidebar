import Foundation

/// Oturumdaki bir alt ajan delegasyonunun liste görünümü.
///
/// Alt ajanlar sağlayıcının `task` aracıyla Doğar; ayrı bir oturumları yoktur,
/// zaman çizelgesindeki `.subagent` etkinlikleridir. Bu kayıt o etkinliklerin
/// okunur izdüşümüdür: liste ve iptal buradan beslenir, yeni kullanıcı arayüzü
/// kurulmaz (`SubagentReportPanelView` tek raporu göstermeye devam eder).
struct SubagentRecord: Equatable, Sendable, Identifiable {
    /// Zaman çizelgesindeki etkinliğin kimliği.
    let id: ProviderActivityID
    /// Kart başlığı (delege edilen işin adı).
    let title: String?
    /// Ara adım özeti.
    let detail: String?
    /// Nihai rapor (`SubagentReportPanelView` bunu okur).
    let report: String?
    /// Etkinliğin o anki evresi.
    let phase: AgentActivityPhase
    /// Başlangıç anı.
    let startedAt: Date
    /// Hangi turun delegasyonu (`nil` = grup turne bağlı değil).
    let turnID: UUID?

    /// Çalışan delegasyon mu.
    var isRunning: Bool {
        phase == .running
    }
}

extension SubagentRecord {
    /// Zaman çizelgesi etkinliğinden liste kaydı kurar.
    init(activity: AgentActivity, turnID: UUID?) {
        self.init(
            id: activity.id,
            title: activity.title,
            detail: activity.detail,
            report: activity.output,
            phase: activity.phase,
            startedAt: activity.startedAt,
            turnID: turnID
        )
    }
}

extension AgentSession {
    /// Oturumdaki bütün alt ajan delegasyonları, yeniden eskiye.
    ///
    /// Kaynak zaman çizelgesidir: ayrı bir depo tutulmaz, sağlayıcı yeni bir
    /// `task` etkinliği bildirdikçe liste büyür.
    var subagents: [SubagentRecord] {
        state.activityGroups.reversed().flatMap { group in
            group.activities.reversed().compactMap { activity in
                guard activity.kind == .subagent else {
                    return nil
                }
                return SubagentRecord(activity: activity, turnID: group.turnID ?? group.id)
            }
        }
    }

    /// Çalışan bir alt ajanı durdurur.
    ///
    /// Çalışma zamanında alt ajan başına iptal ilkeli yoktur: delegasyon koşan
    /// turun parçasıdır, o yüzden çalışan bir kayıt bütün turu iptal eder.
    /// Bitmiş ya da bilinmeyen kayıtta işlem yapmaz.
    ///
    /// - Returns: Bir tur iptal edildiyse `true`.
    @discardableResult
    func cancelSubagent(_ id: ProviderActivityID) async -> Bool {
        guard
            let record = subagents.first(where: { $0.id == id }),
            record.isRunning,
            activeTurnID != nil
        else {
            return false
        }
        await cancel()
        return true
    }
}

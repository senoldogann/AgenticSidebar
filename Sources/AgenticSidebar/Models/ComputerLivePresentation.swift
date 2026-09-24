import Foundation

/// Canlı bilgisayar panelinin durumu: akış mı, boş durum mu?
enum ComputerLiveState: Equatable, Sendable {
    /// Oturum bilgisayarı kullanmıyor: panel boş durum gösterir, yakalama
    /// döngüsü durur.
    case idle
    /// Bilgisayar kullanan tur sürüyor: kareler canlıdır.
    case active(step: ComputerLiveStep)
}

/// Panelin durum satırında gösterilen adım.
struct ComputerLiveStep: Equatable, Sendable {
    let title: String
    let detail: String?
    let isRunning: Bool
}

/// Bilgisayar kullanımının canlı izlenip izlenmeyeceğini saf olarak türetir.
///
/// Kural son tur üzerinedir: oturum meşgulse ve son aktivite grubunda bir
/// `.computer` adımı varsa tur bilgisayar kullanıyordur. Adımlar arasındaki
/// düşünme sırasında da akış sürer (grup aynı turda kalır); tur bitince boş
/// duruma dönülür.
enum ComputerLivePresentation {
    static func state(
        isSessionBusy: Bool,
        groups: [AgentTurnActivityGroup]
    ) -> ComputerLiveState {
        guard isSessionBusy, let group = groups.last else {
            return .idle
        }

        let computerActivities = group.activities.filter { $0.kind == .computer }
        guard let latest = computerActivities.last else {
            return .idle
        }

        // Koşan adım varsa o anlatılır; hepsi bitmişse son adım "bekliyor"
        // olarak kalır, yoksa panel adımlar arasında boşalıp yanıp sönerdi.
        let shown = computerActivities.last { $0.phase == .running } ?? latest
        return .active(
            step: ComputerLiveStep(
                title: shown.title ?? shown.detail ?? "Computer action",
                detail: shown.detail,
                isRunning: shown.phase == .running
            )
        )
    }
}

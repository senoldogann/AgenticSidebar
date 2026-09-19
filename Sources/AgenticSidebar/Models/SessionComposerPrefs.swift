import Foundation

/// Bestecinin oturum başına tercihleri: ajan modu ve hız modu.
///
/// İkisi de `SettingsStore` içinde genel duruyordu: bir sohbette Plan'a
/// geçmek diğer sohbetteki besteciyi de Plan yapıyordu. Her sohbet ayrı
/// olduğu için geçersiz kılmalar burada oturum kimliğine göre saklanır.
/// Geçersiz kılma yoksa genel değer geçerlidir: yeni sohbet o anki genelle
/// başlar, kullanıcı o sohbette değiştirince yalnız o sohbet ayrışır.
/// Arşive yazılmaz; yeniden başlatmada sohbetler genele döner.
@Observable
@MainActor
final class SessionComposerPrefs {
    private var agentModes: [UUID: AgentMode] = [:]
    private var speedModes: [UUID: ResponseSpeedMode] = [:]

    /// Oturumun etkin modu: geçersiz kılma yoksa verilen genel değer.
    func effectiveAgentMode(for sessionID: UUID, default global: AgentMode) -> AgentMode {
        agentModes[sessionID] ?? global
    }

    /// Oturumun etkin hızı: geçersiz kılma yoksa verilen genel değer.
    func effectiveSpeedMode(
        for sessionID: UUID,
        default global: ResponseSpeedMode
    ) -> ResponseSpeedMode {
        speedModes[sessionID] ?? global
    }

    func setAgentMode(_ mode: AgentMode, for sessionID: UUID) {
        agentModes[sessionID] = mode
    }

    func setSpeedMode(_ mode: ResponseSpeedMode, for sessionID: UUID) {
        speedModes[sessionID] = mode
    }

    /// Silinen sohbetlerin tercihleri tutulmaz.
    func discardSessions(notIn liveIDs: Set<UUID>) {
        agentModes = agentModes.filter { liveIDs.contains($0.key) }
        speedModes = speedModes.filter { liveIDs.contains($0.key) }
    }
}

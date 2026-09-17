import Foundation

/// Snap kısayolunun uygulama bağlantısı.
///
/// Zincir: kısayol → `handleSnapHotKey()` → ayar kontrolü → `snap()` →
/// `ComposerDraftCenter.requestRestore` (incelemeli enjeksiyon yolu; doğrudan
/// `send()` yok). `AgenticSidebarApp` bu koordinatörü kurup
/// `appDelegate.snapCoordinator` alanına atar; atama olur olmaz kısayol
/// `didSet` üzerinden kendini kaydeder.
@MainActor
final class ContextSnapCoordinator {
    private let snapService: ContextSnapService
    private let draftCenter: ComposerDraftCenter
    private let settings: SettingsStore
    private let activeSessionID: @Sendable () -> UUID

    init(
        snapService: ContextSnapService,
        draftCenter: ComposerDraftCenter,
        settings: SettingsStore,
        activeSessionID: @escaping @Sendable () -> UUID
    ) {
        self.snapService = snapService
        self.draftCenter = draftCenter
        self.settings = settings
        self.activeSessionID = activeSessionID
    }

    /// Ayar kapalıysa sessizce yok sayar (varsayılan: kapalı).
    func handleSnapHotKey() {
        guard settings.contextSnapEnabled else {
            return
        }
        guard let snap = snapService.snap() else {
            return
        }
        draftCenter.requestRestore(
            text: snap.markdown(),
            sessionID: activeSessionID()
        )
    }
}

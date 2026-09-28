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
    private let activeSessionID: @MainActor @Sendable () -> UUID
    /// Okuma kendi seri kuyruğunda koşar: AppleEvent ve AX çağrıları
    /// eşzamanlı bloklar; Swift'in iş birliği havuzunda koşsalardı art arda
    /// basışlar havuzun iş parçacıklarını tüketebilirdi.
    private static let readQueue = DispatchQueue(
        label: "com.dogan.AgenticSidebar.context-snap",
        qos: .userInitiated
    )
    /// Süren okuma: bu sırada gelen basış yok sayılır, okumalar üst üste binmez.
    private var isSnapInFlight = false

    init(
        snapService: ContextSnapService,
        draftCenter: ComposerDraftCenter,
        settings: SettingsStore,
        activeSessionID: @escaping @MainActor @Sendable () -> UUID
    ) {
        self.snapService = snapService
        self.draftCenter = draftCenter
        self.settings = settings
        self.activeSessionID = activeSessionID
    }

    /// Ayar kapalıysa sessizce yok sayar (varsayılan: kapalı).
    ///
    /// Okuma ana aktörün dışında koşar: tarayıcı URL'si eşzamanlı bir
    /// AppleEvent'tir (varsayılan zaman aşımı ~2 dk), seçili metin AX ile
    /// öndeki uygulamaya sorulur (o uygulama takılıysa saniyelerce bekler).
    /// Ana iş parçacığında koştuğunda kısayol tüm arayüzü donduruyordu.
    /// Hedef oturum kısayolun basıldığı an alınır; okuma sürerken sohbet
    /// değişse de taslak doğru sohbete düşer.
    func handleSnapHotKey() async {
        guard settings.contextSnapEnabled, !isSnapInFlight else {
            return
        }
        isSnapInFlight = true
        defer { isSnapInFlight = false }
        let service = snapService
        let sessionID = activeSessionID()
        let snap: ContextSnap? = await withCheckedContinuation { continuation in
            Self.readQueue.async {
                continuation.resume(returning: service.snap())
            }
        }
        guard let snap else {
            return
        }
        draftCenter.requestRestore(
            text: snap.markdown(),
            attachmentPaths: [],
            sessionID: sessionID
        )
    }
}

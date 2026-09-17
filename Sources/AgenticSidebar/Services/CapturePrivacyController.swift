import AppKit

/// Reflects window sharing protection capabilities against screen captures and recordings.
struct CapturePrivacyCapabilities: Equatable, Sendable {
    /// Uygulamanın pencerelerine bir dışlama ayarının gerçekten uygulandığını
    /// söyler; macOS'un bu ayarı her yakalama yolunda dikkate alması garanti
    /// edilemediği için dil "garanti" değil, uygulanan mekanizmadır.
    let externalCaptureExclusionApplied: Bool
    let limitation: String

    static let current = CapturePrivacyCapabilities(
        externalCaptureExclusionApplied: true,
        limitation: "This app sets NSWindow.sharingType = .none on its windows, which asks macOS to leave them out of system screenshots and standard screen recordings. Capture paths that do not honor the window sharing setting are not covered."
    )
}

struct CapturePrivacyReport: Equatable, Sendable {
    let externalCaptureExclusionApplied: Bool
    let capabilities: CapturePrivacyCapabilities
}

/// Stealth Mode'un tek sahibi.
///
/// Kural burada bir kez kurulur. Bir pencere `sharingType`'ı başka bir
/// pencereden devralmadığı için, sonradan doğan bir sheet ya da panel
/// göründüğü anda kendi başına ayarlanmazsa gizli moddan muaf kalır — eskiden
/// yalnız kuralın kurulduğu andaki `childWindows` gezildiği için tam olarak bu
/// oluyordu: Stealth açıkken açılan bir sheet, kayıtlarda görünür kalıyordu.
/// Bildirim gözlemlerini tutan kutu.
///
/// Kayıtları kendi `deinit`'inde kaldırır: kontrolörün `deinit`'i nonisolated
/// olduğu için ana aktöre ait durumu (gözlemci listesini) oradan okumak
/// yasaktı. Böylece kutu bırakıldığında gözlemler de düşer.
private final class WindowAppearanceObservers {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

@MainActor
final class CapturePrivacyController {
    let capabilities = CapturePrivacyCapabilities.current

    private weak var trackedWindow: NSWindow?
    private var isStealthEnabled: Bool
    private let appearanceObservers = WindowAppearanceObservers()

    /// Kullanıcının tercihi okunana kadar hiçbir pencereye dokunulmaz:
    /// uygulama, bilmediği bir ayarı uygulamış gibi görünmemeli.
    private var hasReadPreference: Bool

    init(isStealthEnabled: Bool = true, hasReadPreference: Bool = false) {
        self.isStealthEnabled = isStealthEnabled
        self.hasReadPreference = hasReadPreference
        observeWindowAppearances()
    }

    @discardableResult
    func configure(window: NSWindow, stealthMode: Bool) -> CapturePrivacyReport {
        trackedWindow = window
        isStealthEnabled = stealthMode
        hasReadPreference = true
        applySharingType(to: window)
        return CapturePrivacyReport(
            externalCaptureExclusionApplied: window.sharingType == .none,
            capabilities: capabilities
        )
    }

    func setStealthMode(_ enabled: Bool) {
        isStealthEnabled = enabled
        hasReadPreference = true

        // Uygulamanın pencereleri tek tek ayarlanır: ana pencere, Ayarlar
        // penceresi ve o an açık olan sheet ya da panel — hepsi aynı tercihe
        // uyar, çünkü Ayarlar'daki söz "pencereyi" değil uygulamayı anlatır.
        for window in NSApp.windows {
            applySharingType(to: window)
        }

        if let trackedWindow {
            applySharingType(to: trackedWindow)
        }
    }

    /// Yeni görünen bir pencereye mevcut ayarı uygular.
    ///
    /// Gözlemci bunu çağırır; testler doğrudan çağırarak çalışma döngüsüne
    /// bağlı kalmaz.
    func adopt(_ window: NSWindow) {
        guard hasReadPreference, window.sharingType != targetSharingType else {
            return
        }
        applySharingType(to: window)
    }

    /// Ana iş parçacığı dışından gelen bildirimler için: pencere kimliğinden
    /// yeniden çözümleme, çünkü `NSWindow` iş parçacıkları arasında taşınamaz.
    func adoptWindow(identified identity: ObjectIdentifier) {
        var candidates = NSApp.windows
        if let trackedWindow {
            candidates.append(trackedWindow)
            candidates.append(contentsOf: trackedWindow.childWindows ?? [])
        }
        guard let window = candidates.first(where: { ObjectIdentifier($0) == identity }) else {
            return
        }
        adopt(window)
    }

    private var targetSharingType: NSWindow.SharingType {
        isStealthEnabled ? .none : .readOnly
    }

    private func applySharingType(to window: NSWindow) {
        window.sharingType = targetSharingType
        for child in window.childWindows ?? [] {
            applySharingType(to: child)
        }
    }

    private func observeWindowAppearances() {
        // `didChangeOcclusionState` bir pencerenin ekranda görünür hâle
        // geldiğini söyler; `didBecomeKey`/`didBecomeMain` ise sheet ve panel
        // gibi odak alan pencereleri yakalar.
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]

        for name in names {
            // `queue: nil` blok, bildirimi gönderen iş parçacığında senkron
            // çalışır. AppKit bu bildirimleri ana iş parçacığında gönderir ve
            // pencere, ekrana geldiği tur içinde ayarlanmış olur — bir sonraki
            // turda değil, yani ilk kare kayıtta görünmez.
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                // `Notification` taşınamaz; izolasyona geçmeden önce yalnız
                // gereken pencereye indirgenir.
                guard let appeared = notification.object as? NSWindow else {
                    return
                }

                // `queue: nil` gönderen iş parçacığında çalışır. Ana iş
                // parçacığındaysa ayar aynı turda uygulanır; değilse yalnız
                // pencerenin kimliği (Sendable) ana kuyruğa taşınır ve pencere
                // orada yeniden çözülür — `NSWindow` üyeleri ana aktöre
                // yalıtımlı olduğu için iş parçacıkları arasında taşınmaz.
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.adopt(appeared)
                    }
                } else {
                    let identity = ObjectIdentifier(appeared)
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.adoptWindow(identified: identity)
                        }
                    }
                }
            }
            appearanceObservers.add(token)
        }
    }
}

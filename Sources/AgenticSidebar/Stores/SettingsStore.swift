import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let menuBarSessionEnabled = "settings.menuBarSessionEnabled"
        static let windowOpacity = "settings.windowOpacity"
        static let colorSchemeMode = "settings.colorSchemeMode"
        static let activeThemeID = "settings.activeThemeID"
        static let contrast = "settings.contrast"
        static let glassOpacity = "settings.glassOpacity"
        static let autoSubmitClipboard = "settings.autoSubmitClipboard"
        static let autoAnalyzeScreenshots = "settings.autoAnalyzeScreenshots"
        static let contextSnapEnabled = "settings.contextSnapEnabled"
        static let globalShortcut = "settings.globalShortcut"
        static let fontFamily = "settings.fontFamily"
        static let fontSize = "settings.fontSize"
        static let codeFontSize = "settings.codeFontSize"
        static let codeWordWrap = "settings.codeWordWrap"
        static let lineSpacing = "settings.lineSpacing"
        static let responseSpeedMode = "settings.responseSpeedMode"
        static let agentMode = "settings.agentMode"
        static let defaultProviderID = "settings.defaultProviderID"
        static let computerUseEnabled = "settings.computerUseEnabled"
        static let chatgptSystemRootPath = "settings.chatgptSystemRootPath"
        static let toolApprovalPolicy = "settings.toolApprovalPolicy"
        static let autonomyNoticeAcknowledged = "settings.autonomyNoticeAcknowledged"
        static let stealthModeEnabled = "settings.stealthModeEnabled"
        static let menuBarIconChoice = "settings.menuBarIconChoice"
        static let sessionNotificationsEnabled = "settings.sessionNotificationsEnabled"
        static let sessionNotificationPreviewEnabled = "settings.sessionNotificationPreviewEnabled"
        static let sessionNotificationSoundEnabled = "settings.sessionNotificationSoundEnabled"
        static let sessionNotificationSound = "settings.sessionNotificationSound"
        static let autoOfferAllOption = "settings.autoOfferAllOption"
        static let autoSelectRecommendedOption = "settings.autoSelectRecommendedOption"
        /// Önceki sürümün bilgisayar kullanımına özel onay anahtarı. Yalnızca göç
        /// için okunur; yeni değer her zaman `toolApprovalPolicy` altına yazılır.
        static let legacyComputerUseApprovalMode = "settings.computerUseApprovalMode"
    }

    /// Varsayılan chatgpt-system deposu; kullanıcı bunu Settings'ten değiştirebilir.
    static let defaultChatgptSystemRootPath = "~/Desktop/chatgpt-system"

    @ObservationIgnored
    private let defaults: UserDefaults

    var menuBarSessionEnabled: Bool {
        didSet {
            defaults.set(menuBarSessionEnabled, forKey: Key.menuBarSessionEnabled)
        }
    }

    var windowOpacity: Double {
        didSet {
            // `didSet` içinde kendine atama gözlemciyi yeniden tetiklemez;
            // erken dönülürse kırpılmış değer bellekte kalır, diskte eski değer
            // kalırdı.
            let clamped = max(0.40, min(1.00, windowOpacity))
            if windowOpacity != clamped {
                windowOpacity = clamped
            }
            defaults.set(windowOpacity, forKey: Key.windowOpacity)
        }
    }

    var colorSchemeMode: ColorSchemeMode {
        didSet {
            defaults.set(colorSchemeMode.rawValue, forKey: Key.colorSchemeMode)
        }
    }

    var activeThemeID: String {
        didSet {
            defaults.set(activeThemeID, forKey: Key.activeThemeID)
        }
    }

    var contrast: Double {
        didSet {
            // `didSet` içinde kendine atama gözlemciyi yeniden tetiklemez;
            // erken dönülürse kırpılmış değer bellekte kalır, diskte eski değer
            // kalırdı.
            let clamped = max(0.80, min(1.50, contrast))
            if contrast != clamped {
                contrast = clamped
            }
            defaults.set(contrast, forKey: Key.contrast)
        }
    }

    var glassOpacity: Double {
        didSet {
            // `didSet` içinde kendine atama gözlemciyi yeniden tetiklemez;
            // erken dönülürse kırpılmış değer bellekte kalır, diskte eski değer
            // kalırdı.
            let clamped = max(0.30, min(1.00, glassOpacity))
            if glassOpacity != clamped {
                glassOpacity = clamped
            }
            defaults.set(glassOpacity, forKey: Key.glassOpacity)
        }
    }

    var autoSubmitClipboard: Bool {
        didSet {
            defaults.set(autoSubmitClipboard, forKey: Key.autoSubmitClipboard)
        }
    }

    var autoAnalyzeScreenshots: Bool {
        didSet {
            defaults.set(autoAnalyzeScreenshots, forKey: Key.autoAnalyzeScreenshots)
        }
    }

    /// Snap Context (⇧⌘D) kısayolu; ilk kez izin isteyen özellik olduğu için
    /// varsayılan kapalıdır.
    var contextSnapEnabled: Bool {
        didSet {
            defaults.set(contextSnapEnabled, forKey: Key.contextSnapEnabled)
        }
    }

    /// The global show/hide shortcut is a stored preference rather than a
    /// hard-coded constant, so changing it never touches the window controller.
    var globalShortcutChoice: GlobalShortcutChoice {
        didSet {
            defaults.set(globalShortcutChoice.rawValue, forKey: Key.globalShortcut)
        }
    }

    var fontFamily: AppFontFamily {
        didSet {
            defaults.set(fontFamily.rawValue, forKey: Key.fontFamily)
        }
    }

    var fontSize: AppFontSize {
        didSet {
            defaults.set(fontSize.rawValue, forKey: Key.fontSize)
        }
    }

    var codeFontSize: CodeFontSize {
        didSet {
            defaults.set(codeFontSize.rawValue, forKey: Key.codeFontSize)
        }
    }

    var codeWordWrap: Bool {
        didSet {
            defaults.set(codeWordWrap, forKey: Key.codeWordWrap)
        }
    }

    var lineSpacing: AppLineSpacing {
        didSet {
            defaults.set(lineSpacing.rawValue, forKey: Key.lineSpacing)
        }
    }

    var responseSpeedMode: ResponseSpeedMode {
        didSet {
            defaults.set(responseSpeedMode.rawValue, forKey: Key.responseSpeedMode)
        }
    }

    /// Build or Plan. Stored like the speed mode because both are properties of
    /// the *next* turn rather than of the transcript.
    var agentMode: AgentMode {
        didSet {
            defaults.set(agentMode.rawValue, forKey: Key.agentMode)
        }
    }

    /// Ayarlardan seçilen sağlayıcı tüm sohbetlerde geçerlidir: yeni oturum
    /// bununla açılır, seçim değişince boşta duran oturumlar da buna geçer.
    /// `nil` = kullanıcı seçmedi, oturum çekirdeğinin ürün varsayılanı çalışır.
    var defaultProviderID: String? {
        didSet {
            defaults.set(defaultProviderID, forKey: Key.defaultProviderID)
        }
    }

    /// chatgpt-system MCP sunucusu üzerinden bilgisayar kontrolü açık mı.
    var computerUseEnabled: Bool {
        didSet {
            defaults.set(computerUseEnabled, forKey: Key.computerUseEnabled)
        }
    }

    /// chatgpt-system deposunun yolu; `~` ile başlayabilir.
    var chatgptSystemRootPath: String {
        didSet {
            defaults.set(chatgptSystemRootPath, forKey: Key.chatgptSystemRootPath)
        }
    }

    /// Ajanın sormadan ne kadarını yapabileceği.
    ///
    /// Tek bir genel karardır — araç başına değil — ve her turun başında anlık
    /// görüntü olarak alınır. Ayarlar ekranından ya da sohbetin üst şeridinden
    /// değiştirilebilir ve **bir sonraki turdan** itibaren geçerlidir: seviye
    /// yönetilen sunucunun yapılandırmasına yazılmaz, o yüzden yeniden başlatma
    /// gerekmez; ama başlamış bir tur, başladığı seviyeyle cevaplanır.
    var toolApprovalPolicy: ToolApprovalPolicy {
        didSet {
            defaults.set(toolApprovalPolicy.rawValue, forKey: Key.toolApprovalPolicy)
        }
    }

    /// Fresh install tam erişimle açıldığı için kullanıcıdan açık kabul
    /// alınır: bu bayrak `true` olana dek Ayarlar'daki onay kartı kabul
    /// şeridini gösterir. Kapatma düğmesi yoktur; görmezden gelmek
    /// kabul sayılmaz, şerit yeniden gösterilir.
    var autonomyNoticeAcknowledged: Bool {
        didSet {
            defaults.set(autonomyNoticeAcknowledged, forKey: Key.autonomyNoticeAcknowledged)
        }
    }

    /// Whether the windows should be excluded from screenshots and screen recordings via NSWindow.sharingType = .none.
    var stealthModeEnabled: Bool {
        didSet {
            defaults.set(stealthModeEnabled, forKey: Key.stealthModeEnabled)
        }
    }

    /// Menu bar icon representation style.
    var menuBarIconChoice: MenuBarIconChoice {
        didSet {
            defaults.set(menuBarIconChoice.rawValue, forKey: Key.menuBarIconChoice)
        }
    }

    /// Whether macOS system notifications are sent when an agent session finishes.
    var sessionNotificationsEnabled: Bool {
        didSet {
            defaults.set(sessionNotificationsEnabled, forKey: Key.sessionNotificationsEnabled)
        }
    }

    /// Whether the completion banner carries a transcript excerpt (up to 160
    /// characters). The excerpt persists in Notification Center, including on
    /// the lock screen, so sensitive sessions should turn it off.
    var sessionNotificationPreviewEnabled: Bool {
        didSet {
            defaults.set(sessionNotificationPreviewEnabled, forKey: Key.sessionNotificationPreviewEnabled)
        }
    }

    /// Whether a sound plays when a session completion notification arrives.
    var sessionNotificationSoundEnabled: Bool {
        didSet {
            defaults.set(sessionNotificationSoundEnabled, forKey: Key.sessionNotificationSoundEnabled)
        }
    }

    /// The selected alert sound played on session completion.
    var sessionNotificationSound: String {
        didSet {
            defaults.set(sessionNotificationSound, forKey: Key.sessionNotificationSound)
        }
    }

    /// Whether question cards automatically present a 'Hepsi / All' choice when 2+ options exist.
    var autoOfferAllOption: Bool {
        didSet {
            defaults.set(autoOfferAllOption, forKey: Key.autoOfferAllOption)
        }
    }

    /// Whether question cards automatically pre-select recommended options.
    var autoSelectRecommendedOption: Bool {
        didSet {
            defaults.set(autoSelectRecommendedOption, forKey: Key.autoSelectRecommendedOption)
        }
    }

    static let availableNotificationSounds: [String] = [
        "Default",
        "Glass",
        "Ping",
        "Pop",
        "Hero",
        "Submarine",
        "Tink",
        "Basso",
        "Purr",
    ]

    func playTestNotificationSound() {
        guard sessionNotificationSoundEnabled else { return }
        if sessionNotificationSound == "Default" {
            NSSound.beep()
        } else {
            NSSound(named: sessionNotificationSound)?.play()
        }
    }

    /// Genel kısayol kaydı başarısız olduysa nedeni; Ayarlar ekranında gösterilir.
    ///
    /// Sessiz bir başarısızlık, kullanıcının hiç çalışmayan bir kısayolu
    /// çalışıyor sanması demekti.
    var globalShortcutError: String?

    /// Eski bilgisayar kullanımı onay modunu yeni genel politikaya çevirir.
    ///
    /// `autoApproveActions`, eski hâlinde bilgisayar *eylemlerini* de sormadan
    /// onaylıyordu. Yeni `approveSafe` onları sorar: ekranda ne olduğunu bilmeden
    /// fare ve klavye kontrolünü sessizce onaylamak "yalnızca güvenli olmayanı
    /// sor" sözüyle çelişirdi. Göç bu yüzden bilinçli olarak daha sıkıdır ve
    /// kullanıcı isterse Tam erişim'e tek tıkla geçebilir.
    static func migratedPolicy(fromLegacyValue rawValue: String) -> ToolApprovalPolicy? {
        switch rawValue {
        case "ask": .ask
        case "autoApproveActions": .approveSafe
        case "fullAccess": .fullAccess
        default: nil
        }
    }

    /// Kabul şeridi görünsün mü: seviye tam erişimken ve kullanıcı henüz
    /// açık seçim yapmamışken `true`. Saf fonksiyondur, doğrudan sınanır.
    static func shouldShowAutonomyNotice(policy: ToolApprovalPolicy, acknowledged: Bool) -> Bool {
        policy == .fullAccess && !acknowledged
    }

    /// Whether the app should render dark.
    ///
    /// The environment's `colorScheme` is consulted **only** for the System
    /// preference, and that is precisely the mode in which this app forces no
    /// scheme onto its windows. In the forced modes the answer is known without
    /// asking, which is what breaks the feedback loop that used to freeze the
    /// app: a preferred scheme is written back into the environment, so reading
    /// it in `.system` mode reported the app's *own* forced choice instead of
    /// the user's — once dark, always dark, no matter how often the system
    /// switched afterwards.
    func isDark(systemColorScheme: ColorScheme) -> Bool {
        switch colorSchemeMode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return systemColorScheme == .dark
        }
    }

    var currentThemePreset: AppThemePreset {
        AppThemes.preset(for: activeThemeID)
    }

    convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults

        if defaults.object(forKey: Key.menuBarSessionEnabled) == nil {
            menuBarSessionEnabled = true
        } else {
            menuBarSessionEnabled = defaults.bool(forKey: Key.menuBarSessionEnabled)
        }

        if defaults.object(forKey: Key.windowOpacity) == nil {
            windowOpacity = 0.95
        } else {
            let stored = defaults.double(forKey: Key.windowOpacity)
            windowOpacity = max(0.40, min(1.00, stored))
        }

        if let rawMode = defaults.string(forKey: Key.colorSchemeMode),
            let mode = ColorSchemeMode(rawValue: rawMode)
        {
            colorSchemeMode = mode
        } else {
            colorSchemeMode = .dark
        }

        if let storedThemeID = defaults.string(forKey: Key.activeThemeID) {
            activeThemeID = AppThemes.normalizedThemeID(from: storedThemeID)
        } else {
            activeThemeID = ThemeIdentifier.nebula.rawValue
        }

        if let rawShortcut = defaults.string(forKey: Key.globalShortcut),
            let choice = GlobalShortcutChoice(rawValue: rawShortcut)
        {
            // A stored choice is kept as it is, including the plain ⌘B that older
            // installs have: rebinding a shortcut the user is used to, without
            // asking, is its own bug. Only a fresh install gets the new default.
            globalShortcutChoice = choice
        } else {
            globalShortcutChoice = .commandShiftB
        }

        if defaults.object(forKey: Key.contrast) == nil {
            contrast = 1.10
        } else {
            let stored = defaults.double(forKey: Key.contrast)
            contrast = max(0.80, min(1.50, stored))
        }

        if defaults.object(forKey: Key.glassOpacity) == nil {
            glassOpacity = 1.00
        } else {
            let stored = defaults.double(forKey: Key.glassOpacity)
            glassOpacity = max(0.30, min(1.00, stored))
        }

        autoSubmitClipboard = defaults.bool(forKey: Key.autoSubmitClipboard)
        autoAnalyzeScreenshots = defaults.bool(forKey: Key.autoAnalyzeScreenshots)
        contextSnapEnabled = defaults.bool(forKey: Key.contextSnapEnabled)

        if let rawFamily = defaults.string(forKey: Key.fontFamily),
            let family = AppFontFamily(rawValue: rawFamily)
        {
            fontFamily = family
        } else {
            fontFamily = .system
        }

        if let rawSize = defaults.string(forKey: Key.fontSize),
            let size = AppFontSize(rawValue: rawSize)
        {
            fontSize = size
        } else {
            fontSize = .regular
        }

        if let rawCodeSize = defaults.string(forKey: Key.codeFontSize),
            let codeSize = CodeFontSize(rawValue: rawCodeSize)
        {
            codeFontSize = codeSize
        } else {
            codeFontSize = .standard
        }

        if defaults.object(forKey: Key.codeWordWrap) == nil {
            codeWordWrap = false
        } else {
            codeWordWrap = defaults.bool(forKey: Key.codeWordWrap)
        }

        if let rawSpacing = defaults.string(forKey: Key.lineSpacing),
            let spacing = AppLineSpacing(rawValue: rawSpacing)
        {
            lineSpacing = spacing
        } else {
            lineSpacing = .normal
        }

        if let rawSpeedMode = defaults.string(forKey: Key.responseSpeedMode),
            let speedMode = ResponseSpeedMode(rawValue: rawSpeedMode)
        {
            responseSpeedMode = speedMode
        } else {
            // Otonomi varsayılanı: hızlı aksiyon. Kullanıcı isterse Normal'e
            // tek tıkla döner; kayıtlı seçim her zaman kazanır.
            responseSpeedMode = .fast
        }

        if let rawAgentMode = defaults.string(forKey: Key.agentMode),
            let mode = AgentMode(rawValue: rawAgentMode)
        {
            agentMode = mode
        } else {
            agentMode = .build
        }

        defaultProviderID = defaults.string(forKey: Key.defaultProviderID)

        if defaults.object(forKey: Key.computerUseEnabled) == nil {
            computerUseEnabled = false
        } else {
            computerUseEnabled = defaults.bool(forKey: Key.computerUseEnabled)
        }

        if let storedRootPath = defaults.string(forKey: Key.chatgptSystemRootPath) {
            chatgptSystemRootPath = storedRootPath
        } else {
            chatgptSystemRootPath = Self.defaultChatgptSystemRootPath
        }

        if let rawPolicy = defaults.string(forKey: Key.toolApprovalPolicy),
            let policy = ToolApprovalPolicy(rawValue: rawPolicy)
        {
            toolApprovalPolicy = policy
        } else if let legacy = defaults.string(forKey: Key.legacyComputerUseApprovalMode),
            let migrated = Self.migratedPolicy(fromLegacyValue: legacy)
        {
            toolApprovalPolicy = migrated
            defaults.set(migrated.rawValue, forKey: Key.toolApprovalPolicy)
        } else {
            // Otonomi varsayılanı: tam erişim. Kabuk, düzenleme, ağ ve
            // bilgisayar kullanımı gözetimsiz çalışır; tam-host JavaScript
            // (`computer_run_js`) yapılandırmada `deny` olduğu için kapalı
            // kalır. Daha sıkı seviye Ayarlar'da tek tık uzaklıkta.
            toolApprovalPolicy = .fullAccess
        }

        autonomyNoticeAcknowledged = defaults.bool(forKey: Key.autonomyNoticeAcknowledged)

        if defaults.object(forKey: Key.stealthModeEnabled) == nil {
            stealthModeEnabled = true
        } else {
            stealthModeEnabled = defaults.bool(forKey: Key.stealthModeEnabled)
        }

        if let rawIcon = defaults.string(forKey: Key.menuBarIconChoice),
            let iconChoice = MenuBarIconChoice(rawValue: rawIcon)
        {
            menuBarIconChoice = iconChoice
        } else {
            menuBarIconChoice = .systemSliders
        }

        if defaults.object(forKey: Key.sessionNotificationsEnabled) == nil {
            sessionNotificationsEnabled = true
        } else {
            sessionNotificationsEnabled = defaults.bool(forKey: Key.sessionNotificationsEnabled)
        }

        if defaults.object(forKey: Key.sessionNotificationPreviewEnabled) == nil {
            sessionNotificationPreviewEnabled = true
        } else {
            sessionNotificationPreviewEnabled = defaults.bool(forKey: Key.sessionNotificationPreviewEnabled)
        }

        if defaults.object(forKey: Key.sessionNotificationSoundEnabled) == nil {
            sessionNotificationSoundEnabled = true
        } else {
            sessionNotificationSoundEnabled = defaults.bool(forKey: Key.sessionNotificationSoundEnabled)
        }

        if let sound = defaults.string(forKey: Key.sessionNotificationSound) {
            sessionNotificationSound = sound
        } else {
            sessionNotificationSound = "Glass"
        }

        if defaults.object(forKey: Key.autoOfferAllOption) == nil {
            autoOfferAllOption = true
        } else {
            autoOfferAllOption = defaults.bool(forKey: Key.autoOfferAllOption)
        }

        if defaults.object(forKey: Key.autoSelectRecommendedOption) == nil {
            autoSelectRecommendedOption = true
        } else {
            autoSelectRecommendedOption = defaults.bool(forKey: Key.autoSelectRecommendedOption)
        }
    }
}

extension SettingsStore {
    enum MenuBarIconChoice: String, CaseIterable, Identifiable {
        case systemSliders = "slider.horizontal.3"
        case cpuChip = "cpu"
        case activityGauge = "gauge.with.dots.needle.bottom.50percent"
        case minimalDot = "dot.circle"
        case systemGrid = "circle.grid.2x2"
        case sidebar = "sidebar.leading"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .systemSliders: "System Controls (Slider)"
            case .cpuChip: "Hardware Monitor (CPU)"
            case .activityGauge: "Activity Gauge"
            case .minimalDot: "Minimalist Dot"
            case .systemGrid: "System Grid"
            case .sidebar: "Sidebar (Original)"
            }
        }

        var systemImage: String {
            rawValue
        }
    }
}

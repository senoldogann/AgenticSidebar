import Foundation

/// Bölmeden gelen inspector sekmesi açma isteği.
///
/// İkincil bölmenin başlığı (`SplitPaneHeader`) bölmenin inspector sekmelerine
/// erişemez; sekmeler `ConversationDetailView` içindeki `@State` alanında
/// durur. `object` açılması istenen bölmenin kimliğidir (`paneID`); her bölme
/// yalnız kendi kimliğini dinler, böylece yan yana iki terminal birbirini
/// açmaz. Tekli düzende başlık olmadığı için aynı bildirimleri araç
/// çubuğundaki düğmeler (`RootChatView`) birincil bölme için gönderir.
extension Notification.Name {
    static let openPaneTerminal = Notification.Name("AgenticSidebar.openPaneTerminal")

    /// Sağ panelde tarayıcı sekmesini açar.
    static let openPaneBrowser = Notification.Name("AgenticSidebar.openPaneBrowser")

    /// Sağ panelde iOS Simülatörü sekmesini açar.
    static let openPaneSimulator = Notification.Name("AgenticSidebar.openPaneSimulator")

    /// Sağ panelde bilgisayar kullanımı canlı görüntü sekmesini açar.
    static let openPaneComputerLive = Notification.Name("AgenticSidebar.openPaneComputerLive")

    /// Sağ panelde oturumun canlı dosya değişiklikleri sekmesini açar.
    /// Özet tıklama anında hesaplanır, akış sırasında yoktan var olmaz.
    static let openPaneSessionChanges = Notification.Name("AgenticSidebar.openPaneSessionChanges")
}

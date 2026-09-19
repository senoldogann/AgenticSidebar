import Foundation

/// Bölmeden gelen terminal açma isteği.
///
/// İkincil bölmenin başlığı (`SplitPaneHeader`) bölmenin inspector sekmelerine
/// erişemez; sekmeler `ConversationDetailView` içindeki `@State` alanında
/// durur. `object` açılması istenen bölmenin kimliğidir (`paneID`); her bölme
/// yalnız kendi kimliğini dinler, böylece yan yana iki terminal birbirini
/// açmaz. Tekli düzende başlık olmadığı için aynı bildirimi araç çubuğundaki
/// terminal düğmesi (`RootChatView`) birincil bölme için gönderir.
extension Notification.Name {
    static let openPaneTerminal = Notification.Name("AgenticSidebar.openPaneTerminal")
}

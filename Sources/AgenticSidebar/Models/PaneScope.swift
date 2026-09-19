import Foundation

/// Izgara yuvası. `primary` (sol-üst) sabitlenmez; atanmamışken aktif oturumu
/// izler. Diğer yuvalar sabitlenmiş oturum ya da boştur.
///
/// Ham değerler bölme bildirimleri (`openPaneTerminal` nesnesi) ve terminal
/// sekmesi kimliği (`terminal:<ham>`) ile aynıdır, o yüzden değişemez:
/// "primary"/"secondary" kablosu bozulur.
enum PaneSlot: String, CaseIterable, Sendable {
    case primary
    case secondary
    case tertiary
    case quaternary
}

/// Düzen kipi: tekli, yan yana ikili, 2×2 dörtlü.
enum PaneLayoutMode: String, Sendable {
    case single
    case dual
    case quad
}

/// Bölmenin kimliği: hangi yuva + hangi oturum.
///
/// `sessionID` `nil` iki anlama gelir: birincil yuvada aktif oturum izlenir,
/// diğer yuvalarda yuva boştur (yer-tutucu gösterilir, aktif oturuma
/// düşülmez — yoksa iki bölme aynı sohbeti gösterirdi).
struct PaneScope: Equatable, Sendable {
    let slot: PaneSlot
    let sessionID: UUID?

    init(slot: PaneSlot, sessionID: UUID?) {
        self.slot = slot
        self.sessionID = sessionID
    }

    /// Bildirim ve terminal anahtarlarında taşınan bölme kimliği.
    var paneID: String {
        slot.rawValue
    }

    var isPrimary: Bool {
        slot == .primary
    }
}

extension Notification.Name {
    /// Dallanan sohbetin üreten bölmeye yerleşme isteği. `object` sözlüğü
    /// `["slot": yuvanın ham değeri, "session": dalın kimliği]` taşır; her
    /// bölme konağı yalnız kendi yuvasını dinler.
    static let adoptForkedBranch = Notification.Name("AgenticSidebar.adoptForkedBranch")
}

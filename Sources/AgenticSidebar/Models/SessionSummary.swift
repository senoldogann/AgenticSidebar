import Foundation

/// One row of the session list.
///
/// Deliberately narrow: it carries only values that change on turn boundaries,
/// so a streaming background session does not re-render the sidebar 25 times a
/// second.
struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let isBusy: Bool
    let status: AgentSessionStatus
    let completedAt: Date?
    /// Creation date of the newest message. Restored conversations carry no
    /// `completedAt` (a turn never survives relaunch), so the sidebar needs a
    /// real timestamp to show instead of claiming the session is empty.
    let lastMessageAt: Date?
    /// Oturumun oluşturulma zamanı; sıralama ve tarih filtresi için kullanılır.
    let createdAt: Date
    /// Kullanıcının verdiği başlık; boşsa otomatik başlık gösterilir.
    let customTitle: String?
    /// Sabitlenen oturumlar listenin üstünde durur ve budamada en son düşer.
    let isPinned: Bool

    init(
        id: UUID,
        title: String,
        isBusy: Bool,
        status: AgentSessionStatus,
        completedAt: Date?,
        lastMessageAt: Date?,
        createdAt: Date = Date(),
        customTitle: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isBusy = isBusy
        self.status = status
        self.completedAt = completedAt
        self.lastMessageAt = lastMessageAt
        self.createdAt = createdAt
        self.customTitle = customTitle
        self.isPinned = isPinned
    }

    /// Ekranda gösterilen başlık: özel başlık varsa o, yoksa otomatik başlık.
    var displayTitle: String {
        guard let customTitle else {
            return title
        }
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    /// Son kullanım zamanı: son mesaj, yoksa turun bitişi.
    var lastUsedAt: Date? {
        lastMessageAt ?? completedAt
    }

    /// Filtreleme/sıralama için referans zaman; mesajsız oturumda oluşturulma.
    var referenceDate: Date {
        lastUsedAt ?? createdAt
    }
}

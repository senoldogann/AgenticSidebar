import Foundation

/// Oturum başına son yan soru değişimleri. Yalnızca bellekte yaşar:
/// transkripte yazılmaz, arşive girmez, oturum silinince düşer.
struct SideQuestionMemory: Sendable {
    static let maximumExchangesPerSession = 20

    private var exchangesBySession: [UUID: [SideExchange]] = [:]

    func exchanges(for sessionID: UUID) -> [SideExchange] {
        exchangesBySession[sessionID] ?? []
    }

    mutating func append(sessionID: UUID, exchange: SideExchange) {
        var list = exchangesBySession[sessionID] ?? []
        list.append(exchange)
        if list.count > Self.maximumExchangesPerSession {
            list.removeFirst(list.count - Self.maximumExchangesPerSession)
        }
        exchangesBySession[sessionID] = list
    }

    mutating func drop(sessionID: UUID) {
        exchangesBySession.removeValue(forKey: sessionID)
    }
}

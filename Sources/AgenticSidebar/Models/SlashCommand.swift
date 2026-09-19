import Foundation

/// Bestecideki yerleşik eğik-çizgi komutları (`/btw`, `/goal`, `/compact`).
///
/// Bunlar beceri (`skill`) değildir: beceriler tura etiket olarak eklenir,
/// komutlar ise gönderimde yakalanıp kendi akışına yönlenir. `/` öneri
/// paneli iki bölümü üst üste gösterir: önce komutlar, sonra beceriler.
/// Saf değer tipidir; penceresiz test edilir.
struct SlashCommand: Identifiable, Equatable, Sendable {
    /// Eğik çizgisiz ad (`btw`, `goal`).
    let name: String
    /// Listede adın altında görünen tek satırlık açıklama.
    let detail: String
    /// Seçimde taslağa yazılan önek (`/btw ` gibi, sondaki boşlukla).
    var prefix: String { "/\(name) " }

    var id: String { name }

    /// `/goal` hedef döngüsü: projede durmadan çalışır, kapılar yeşillenince
    /// durur. Ayrıntı `GoalOrchestrator` tarafındadır.
    static let goal = SlashCommand(
        name: "goal",
        detail: "Run an autonomous goal loop until gates are green"
    )
    /// `/btw` yan soru: turu kesmeden, transkripte yazmadan sorar.
    static let btw = SlashCommand(
        name: "btw",
        detail: "Ask a side question without interrupting the turn"
    )
    /// `/compact` bağlam sıkıştırma: düşen ön eki özetler, sunucu tarafını
    /// döndürür. Transkripte yazmaz; özet sonraki isteklerin başına eklenir.
    static let compact = SlashCommand(
        name: "compact",
        detail: "Summarize dropped context and rotate the backend session"
    )

    /// Paneldeki sabit sıra: önce hedef, sonra yan soru, sonra sıkıştırma.
    static let all: [SlashCommand] = [.goal, .btw, .compact]

    /// Sorguyla süzme: boş sorgu hepsini verir, dolu sorgu adın içinde
    /// geçer (büyük/küçük harf duyarsız). `query` eğik çizgisiz gelir
    /// (`ExtensionTrigger.query` gibi).
    static func matching(query: String) -> [SlashCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return all
        }
        return all.filter { $0.name.lowercased().contains(needle) }
    }

    /// `/goal hedef` önekini ayıklar: `/goal` + boşluk + boş-olmayan hedef.
    /// `ComposerView.sideQuestion(from:)` ile aynı sözleşme; büyük/küçük
    /// harf duyarsızdır. Eşleşmezse `nil` döner, metin normal gönderilir.
    static func parseGoal(from text: String) -> String? {
        let prefix = "/goal"
        guard text.count > prefix.count else {
            return nil
        }
        guard text.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let remainder = text.dropFirst(prefix.count)
        guard remainder.first?.isWhitespace == true else {
            return nil
        }
        let objective = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return objective.isEmpty ? nil : objective
    }

    /// Yalın `/compact`: argümansız, büyük/küçük harf duyarsız tam eşleşme.
    /// `/compact foo` gibi kuyruklu yazım komut değildir, düz metin gider.
    static func isCompactCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact"
    }
}

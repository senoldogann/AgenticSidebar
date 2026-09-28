import Foundation

/// Bestecideki yerleşik eğik-çizgi komutları (`/btw`, `/goal`).
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
    /// `/model` model seçimi: bestecideki model menüsüyle aynı listeden
    /// (`ProviderGateway` model listesi) beslenir, tura yazılmaz.
    static let model = SlashCommand(
        name: "model",
        detail: "Switch the model for this conversation"
    )
    /// Paneldeki sabit sıra: önce hedef, sonra yan soru, sonra model.
    static let all: [SlashCommand] = [.goal, .btw, .model]

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

    /// İçeriksiz komut adı (`/btw`, `/btw `, `/goal`): soru/hedef yoksa
    /// transkripte yazılmaz, ipucu gösterilir. `parseGoal` ve
    /// `ComposerView.sideQuestion(from:)` ile aynı önek sözleşmesi.
    static func bareCommandName(from text: String) -> String? {
        let lowered = text.lowercased()
        for command in all {
            let prefix = "/\(command.name)"
            guard lowered.hasPrefix(prefix) else {
                continue
            }
            let remainder = text.dropFirst(prefix.count)
            guard remainder.isEmpty || remainder.allSatisfy({ $0.isWhitespace }) else {
                continue
            }
            return command.name
        }
        return nil
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

    /// `/model sorgu` önekini ayıklar: `/model` + boşluk + boş-olmayan sorgu.
    /// İçeriksiz `/model` `bareCommandName` yoluna düşer (ipucu gösterilir).
    /// Büyük/küçük harf duyarsızdır, eşleşmezse `nil` döner.
    static func parseModelQuery(from text: String) -> String? {
        let prefix = "/model"
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
        let query = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    /// Model veri kaynağı: `ProviderGateway` model listesinde (`availableModels`)
    /// sorguyla süzme yapar. Boş sorgu hepsini verir; dolu sorgu görünen ad ya
    /// da kimlikte geçer (büyük/küçük harf duyarsız). Saf ve test edilebilir.
    static func matchingModels(query: String, in models: [ProviderModelCapability]) -> [ProviderModelCapability] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return models
        }
        return models.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.id.rawValue.localizedCaseInsensitiveContains(needle)
        }
    }
}

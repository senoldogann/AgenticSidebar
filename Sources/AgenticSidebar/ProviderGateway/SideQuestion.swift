import Foundation

/// Yan soru (`/btw`) sözleşmesi: ana oturumun bağlamını gören, onu
/// değiştirmeyen tek-atımlık soru.
///
/// Claude Code paritesi: ana tur çalışırken bile sorulur, araç kullanmaz,
/// soru ve cevap geçmişe yazılmaz, panelden kapatılır, hata ana oturuma
/// dokunmaz. Provider-bağımsızdır: her runtime kendi izolasyonuyla
/// (`answerSideQuestion`) implemente eder.
struct SideQuestionQuery: Equatable, Sendable {
    /// Yanıtın hangi sağlayıcı/model/varyantla üretileceği: oturumun
    /// yapılandırması aynen devralınır, tüm ayarlarla sorunsuz çalışır.
    let configuration: SessionConfiguration
    /// Soru anındaki transkript (soru dahil değildir); runtime bağlamı
    /// buradan kurar. Bütçeyle kırpılmış gelir.
    let historyMessages: [ChatMessage]
    /// Önceki turların araç özetleri; ana turdaki preamble disipliniyle taşınır.
    let activityGroups: [AgentTurnActivityGroup]
    /// Aynı oturumdaki önceki yan değişimler (soru+cevap, düz metin).
    /// Bellek `SideQuestionMemory`dedir, transkripte yazılmaz.
    let followups: [SideExchange]
    /// Kullanıcının `/btw` sorusu.
    let question: String
    /// Oturumun etkin hız ve ajan modu aynen devralınır.
    let speedMode: ResponseSpeedMode
    let mode: AgentMode
    /// Yuvarlanan bağlam özeti (`/compact`): boşken maliyet yoktur.
    /// Varsayılan değerli `let` memberwise init'e girmediği için `var`:
    /// üretim yolları özeti geçer, çağırmayan çağrı yerleri varsayılanı alır.
    var contextSummary: String = ""
}

/// Bellekte tutulan tek yan değişim: soru ve düz-metin cevabı.
/// Transkript dışıdır; oturum silinince düşer.
struct SideExchange: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let question: String
    let answer: String

    init(id: UUID = UUID(), question: String, answer: String) {
        self.id = id
        self.question = question
        self.answer = answer
    }

    /// Takip bağlamı transkript mesajlarına düz taşınır: soru kullanıcı,
    /// cevap asistandır. Araç çıktısı taşınmaz.
    func messages() -> [ChatMessage] {
        [
            ChatMessage(role: .user, text: question),
            ChatMessage(role: .assistant, text: answer),
        ]
    }
}

/// Sunum katmanının `SideQuestionService`e verdiği anlık görüntü: soru
/// anındaki runtime, yapılandırma ve geçmiş. Turn makinesine dokunulmaz.
struct SideQuestionContext: Sendable {
    let runtime: any ProviderRuntime
    let configuration: SessionConfiguration
    let messages: [ChatMessage]
    let activityGroups: [AgentTurnActivityGroup]
    /// Sorunun sorulduğu andaki yuvarlanan özet; yan soru da unutmasın diye.
    /// `let` + varsayılan memberwise init'ten düşürürdü (bkz. SideQuestionQuery).
    var contextSummary: String = ""
}

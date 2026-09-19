import Foundation

/// Yazılmakta olan mesajın tamamı: metin, ekler ve etiketler.
///
/// `ComposerView` içinden buraya taşındı: taslak görünümün `@State` alanında
/// dururken tekli↔yan yana geçişte görünüm yok oluyor ve yazılmamış metin,
/// ekler ve etiketler kayboluyordu (kullanıcıya "diğer sohbetin bestecisi
/// kapandı" olarak görünüyordu). Burası uygulama ömrü boyunca yaşar, o yüzden
/// bölme açılıp kapansa da her oturumun taslağı korunur.
struct ComposerDraft: Equatable {
    var text: String
    var attachedURLs: [URL]
    /// Sonraki tur için kullanıcının etiketlediği uzantılar. Metnin içinde
    /// değil ayrı durur, böylece ajana giden metin kullanıcının yazdığı metin
    /// olur.
    var selectedTags: [ExtensionTag]

    static let empty = ComposerDraft(text: "", attachedURLs: [], selectedTags: [])
}

/// Bellek-içi besteci taslakları: oturum kimliğine göre saklanır.
///
/// Diskteki `ComposerDraftStore` yeniden başlatmada yaşar, bu depo ise
/// çalışırken görünüm yeniden kurulmalarında yaşar. İki bölme de aynı depoyu
/// okur: her bölme kendi oturumunun taslağını görür, hiçbiri diğerini ezmez.
/// Etiketler diske yazılmadığı için yalnız burada durur.
@Observable
@MainActor
final class ComposerDraftMemory {
    var drafts: [UUID: ComposerDraft] = [:]

    /// Silinen sohbetlerin taslakları tutulmaz.
    func discardSessions(notIn liveIDs: Set<UUID>) {
        drafts = drafts.filter { liveIDs.contains($0.key) }
    }
}

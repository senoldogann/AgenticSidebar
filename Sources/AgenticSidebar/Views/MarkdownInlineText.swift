import Foundation

/// Inline markdown for a message body.
///
/// `Text(LocalizedStringKey(_:))` renders inline markdown, but it also treats
/// the message as a *localization key*: a stray `.strings` entry could replace
/// the user's text, and the string is parsed as a format string. Building an
/// `AttributedString` directly keeps the emphasis and code-span styling without
/// giving message content localization or format semantics.
enum MarkdownInlineText {
    static func attributed(from text: String) -> AttributedString {
        // Her flush tüm transkript gövdelerini yeniden değerlendirir; metni
        // değişmeyen satırların Foundation parse'ı bu önbellekten döner.
        // Büyüyen kuyruk metni her flush'ta yenidir, o yine ayrıştırılır.
        if let cached = MarkdownInlineCache.shared.attributed(for: text) {
            return cached
        }
        let result: AttributedString = {
            do {
                return try AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )
            } catch {
                // Half-typed markdown is normal mid-stream ("**bold" before the
                // closing run arrives), so malformed input falls back to the literal
                // text instead of dropping the message.
                return AttributedString(text)
            }
        }()
        MarkdownInlineCache.shared.store(result, for: text)
        return result
    }
}

/// Satır-içi `AttributedString` parse sonuçlarının sınırlı önbelleği.
///
/// Blok düzeyi `MarkdownParseStore` ile kaplıdır; burası onun altındaki
/// `Text(...)` başına Foundation parse maliyetini kapatır. Kilit korumalıdır
/// çünkü saf yardımcı her iş parçacığından çağrılabilir; değer anlamiği +
/// kilit erişimi güvenli kılar (`@unchecked` gerekçesi budur).
final class MarkdownInlineCache: @unchecked Sendable {
    static let shared = MarkdownInlineCache()

    static let maximumEntries = 512
    static let maximumTotalCharacters = 300_000

    private let lock = NSLock()
    private var entries: [String: AttributedString] = [:]
    /// Least recently used first.
    private var recency: [String] = []
    private var totalCharacters = 0

    func attributed(for text: String) -> AttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[text] else {
            return nil
        }
        if let index = recency.firstIndex(of: text) {
            recency.remove(at: index)
            recency.append(text)
        }
        return value
    }

    func store(_ value: AttributedString, for text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard entries[text] == nil else {
            return
        }
        entries[text] = value
        recency.append(text)
        totalCharacters += text.count
        while recency.count > Self.maximumEntries
            || (totalCharacters > Self.maximumTotalCharacters && recency.count > 1)
        {
            let oldest = recency.removeFirst()
            totalCharacters -= oldest.count
            entries[oldest] = nil
        }
    }

    /// Used by the tests to start from a known state.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        recency.removeAll()
        totalCharacters = 0
    }
}

import Foundation

/// Keeps a request transcript inside a character budget so a long conversation
/// does not silently overrun the model context window.
///
/// The estimate is intentionally simple — roughly four characters per token —
/// because it only has to decide *when* to trim: both adapters otherwise treat
/// the transcript as opaque text, and a provider-side overflow is still mapped
/// to `AgentSessionError.contextLimitExceeded` if the estimate is ever too
/// generous.
struct TranscriptBudget: Equatable, Sendable {
    static let charactersPerToken = 4
    static let defaultCharacterBudget = 96_000
    /// Kayan pencerenin sert tavanı: bütçe ne derse desin istekte en yeni
    /// `maximumKeptMessages` mesajdan fazlası taşınmaz. Binlerce minik
    /// mesajın bütçeyi baypas edip isteği şişirmesini engeller.
    static let maximumKeptMessages = 500

    struct Selection: Equatable, Sendable {
        let messages: [ChatMessage]
        let droppedMessageCount: Int
    }

    let characterBudget: Int

    init(characterBudget: Int = TranscriptBudget.defaultCharacterBudget) {
        self.characterBudget = max(1_000, characterBudget)
    }

    static func approximateTokenCount(for text: String) -> Int {
        // `count` yerine `utf8.count`: grapheme sayımı bütün metni dolaşır,
        // bayt sayımı ise eşik ön elemesi için yeterli ve ucuzdur.
        (text.utf8.count + charactersPerToken - 1) / charactersPerToken
    }

    /// Keeps the newest messages that fit, dropping whole messages from the
    /// oldest end so a request never contains half a turn.
    func select(from messages: [ChatMessage]) -> Selection {
        guard !messages.isEmpty else {
            return Selection(messages: [], droppedMessageCount: 0)
        }

        var kept: [ChatMessage] = []
        var usedCharacters = 0

        for message in messages.reversed() {
            let cost = Self.approximateCharacters(of: message)

            // The newest message is always kept: the user just wrote it, and a
            // request without it would be meaningless.
            if !kept.isEmpty, usedCharacters + cost > characterBudget {
                break
            }

            kept.append(message)
            usedCharacters += cost
        }

        kept.reverse()

        // Sert kayan pencere: bütçe sığdırsa bile en yeni N mesaj tutulur,
        // ön ek düşer. En yeni mesaj sondadır, `removeFirst` ona dokunmaz.
        if kept.count > Self.maximumKeptMessages {
            kept.removeFirst(kept.count - Self.maximumKeptMessages)
        }

        // Start the window on a user turn when possible: an assistant reply with
        // no question in front of it reads like a stray assertion to the model.
        while kept.count > 1, kept.first?.role == .assistant {
            kept.removeFirst()
        }

        return Selection(
            messages: kept,
            droppedMessageCount: messages.count - kept.count
        )
    }

    static func approximateCharacters(of message: ChatMessage) -> Int {
        message.text.utf8.count
            + message.attachmentPaths.reduce(0) { $0 + $1.utf8.count }
            + 16
    }
}

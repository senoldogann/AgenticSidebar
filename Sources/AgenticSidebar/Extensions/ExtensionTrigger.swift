import Foundation

/// What the user is in the middle of typing in the composer: `@` for the MCP
/// servers and plugins a turn may use, `/` for the skills it should follow.
///
/// Kept out of the view so the rule that decides when the panel appears — the
/// trigger has to be the word currently being typed — is testable without a
/// window.
struct ExtensionTrigger: Equatable, Sendable {
    let kinds: [ExtensionKind]
    /// What follows the trigger character.
    let query: String
    /// Where the token sits in the draft, so choosing a suggestion can remove
    /// exactly it and leave the sentence intact.
    let tokenRange: Range<String.Index>

    /// How much of the end of the draft is examined.
    ///
    /// Only the word being typed can be a trigger, so the scan runs backwards
    /// from the end and stops at that word's start. A pasted book therefore costs
    /// the same as a one-line prompt — the earlier forward scan walked the whole
    /// draft on every keystroke, which is what made large drafts feel stuck.
    static let maximumTailLength = 256

    static func detected(
        in text: String,
        kindsForTrigger: (Character) -> [ExtensionKind] = ExtensionTrigger.defaultKinds
    ) -> ExtensionTrigger? {
        guard !text.isEmpty else {
            return nil
        }

        // A `Substring` shares the parent's indices, so the range found here is
        // already expressed in the draft's own coordinates.
        let tail = text.suffix(maximumTailLength)
        var tokenStart = tail.startIndex
        var index = tail.endIndex

        while index > tail.startIndex {
            let previous = tail.index(before: index)
            if tail[previous].isWhitespace {
                break
            }
            tokenStart = previous
            index = previous
        }

        // The word reaches past the window: it is not the word being typed any
        // more, and pretending otherwise would offer a trigger for a token that
        // was never finished.
        if tokenStart == tail.startIndex, tail.count >= maximumTailLength {
            return nil
        }

        let token = text[tokenStart...]
        guard let first = token.first else {
            return nil
        }

        let kinds = kindsForTrigger(first)
        guard !kinds.isEmpty else {
            return nil
        }

        let query = String(token.dropFirst())
        guard !query.contains(where: { $0.isWhitespace }) else {
            return nil
        }

        return ExtensionTrigger(
            kinds: kinds,
            query: query,
            tokenRange: tokenStart..<text.endIndex
        )
    }

    static func defaultKinds(for character: Character) -> [ExtensionKind] {
        switch character {
        case "@": [.mcp, .plugin]
        case "/": [.skill]
        default: []
        }
    }
}

import Foundation

/// What the composer's controls need to know about a draft, answered without
/// walking the whole draft.
///
/// A pasted document makes every per-keystroke cost proportional to the draft
/// unless the questions are asked carefully: `trimmingCharacters` allocates a
/// copy of the entire text, and `String.count` walks it to count graphemes.
/// Nothing here allocates, and nothing here reads more than a bounded prefix.
enum ComposerDraftMetrics {
    /// How much of a draft is measured when sizing the editor.
    ///
    /// The editor is capped at a few lines, so a prefix is enough to know the
    /// text has outgrown that cap — and measuring the *whole* document with
    /// text layout on every keystroke is what made a large paste feel stuck.
    static let heightMeasurementPrefixBytes = 2_048

    /// The same limit, in the unit the text view actually lays out.
    static let maximumMeasuredHeight: CGFloat = 104

    /// Whether the draft holds anything but whitespace.
    ///
    /// No allocation, and the first non-space character ends the walk.
    static func hasContent(_ draft: String) -> Bool {
        draft.contains { !$0.isWhitespace }
    }

    /// The prefix of the draft that is worth measuring for height.
    ///
    /// `utf8.count` is O(1) on a native string, so this does not pay for the
    /// document either — unlike `prefix(_:)` on the character view, which would
    /// have to count from the start.
    static func measuredPrefix(
        of draft: String,
        limit: Int = heightMeasurementPrefixBytes
    ) -> String {
        guard draft.utf8.count > limit else {
            return draft
        }

        return String(decoding: draft.utf8.prefix(limit), as: UTF8.self)
    }

    /// A cheap, allocation-free fingerprint of a draft that is as long as it is
    /// likely to be worth comparing in full.
    static func fingerprint(of draft: String) -> Int {
        var hasher = Hasher()
        hasher.combine(draft.utf8.count)

        // A bounded sample: the ends are what typing changes.
        hasher.combine(draft.prefix(32))
        hasher.combine(draft.suffix(32))
        return hasher.finalize()
    }
}

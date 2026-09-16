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
    }
}

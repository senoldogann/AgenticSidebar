import Foundation

/// A bounded copy of the last response a provider gave us that we could not read.
///
/// `ProviderRuntimeError` carries no payload — it is `Equatable` and travels
/// through many layers — so an unmapped HTTP status reached the user as
/// “The provider returned a response this app could not interpret.”, which names
/// neither the status nor the body. This is the side channel that fixes that:
/// the client records what came back, and the error message reads it.
///
/// Deliberately small and last-one-wins: a diagnostic, not a log. The snippet is
/// truncated and whitespace-collapsed so a stray HTML error page cannot fill the
/// screen, and it is only ever surfaced when a request has already failed.
final class ProviderResponseDiagnostics: @unchecked Sendable {
    static let shared = ProviderResponseDiagnostics()

    /// Long enough to hold a provider's JSON error object, short enough to read.
    static let maximumSnippetLength = 400

    private let lock = NSLock()
    /// One entry, not one per provider: a failure message is read immediately
    /// after the failure that produced it, and the last one is the one on screen.
    private var last: String?

    func record(provider: String, statusCode: Int?, body: String) {
        var parts: [String] = [provider]
        if let statusCode {
            parts.append("HTTP \(statusCode)")
        }

        let snippet = Self.snippet(from: body)
        if !snippet.isEmpty {
            parts.append(snippet)
        }

        let entry = parts.joined(separator: " · ")

        lock.lock()
        last = entry
        lock.unlock()

        // `.private`, not `.public`: an error body can echo request fragments —
        // model ids, prompt text, account or org identifiers — and this same file
        // documents that request bodies are never logged. The snippet still
        // reaches the user through the error banner, which is where it is useful.
        AppLog.lifecycle.error(
            "Unreadable provider response: \(entry, privacy: .private)"
        )
    }

    /// What the user is shown after the generic sentence, when there is anything
    /// to show. Just the response: the caller owns the sentence.
    func detail() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func reset() {
        lock.lock()
        last = nil
        lock.unlock()
    }

    /// One line, bounded. JSON is kept as-is apart from collapsed whitespace, so a
    /// provider's own error message survives intact.
    static func snippet(from body: String) -> String {
        let collapsed = body
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")

        guard collapsed.count > maximumSnippetLength else {
            return collapsed
        }

        return String(collapsed.prefix(maximumSnippetLength)) + "…"
    }
}

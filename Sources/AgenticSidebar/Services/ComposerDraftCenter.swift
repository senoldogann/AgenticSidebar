import Foundation

/// Hands a message back to the composer from elsewhere in the window.
///
/// The draft lives inside `ComposerView`, so the transcript cannot put text into
/// the field directly. "Write this again" on an earlier message needs exactly
/// that, and this center keeps the two views from knowing about each other: the
/// transcript says *what* should be edited and for which session, the composer
/// decides how it lands in the field it owns.
@Observable
@MainActor
final class ComposerDraftCenter {
    struct RestoreRequest: Identifiable, Equatable {
        let id: UUID
        /// A message belongs to one conversation, and drafts are per session, so
        /// the request has to name the session it is for: a restore that landed
        /// in whichever chat happened to be open would type into the wrong field.
        let sessionID: UUID
        let text: String
        let attachmentPaths: [String]
    }

    private(set) var pending: RestoreRequest?

    @discardableResult
    func requestRestore(
        text: String,
        attachmentPaths: [String] = [],
        sessionID: UUID
    ) -> RestoreRequest {
        let request = RestoreRequest(
            id: UUID(),
            sessionID: sessionID,
            text: text,
            attachmentPaths: attachmentPaths
        )
        pending = request
        return request
    }

    /// Takes the pending request and leaves none behind.
    ///
    /// The composer applies a restore once; a request that stayed pending would
    /// re-apply on the next redraw and keep appending the same message.
    func consumePending() -> RestoreRequest? {
        defer { pending = nil }
        return pending
    }
}

/// Where a restored message lands in a field that may already hold a draft.
enum ComposerDraftPlacement {
    /// Appends rather than replaces.
    ///
    /// Overwriting would destroy a draft the user was still writing but had not
    /// sent — work they never agreed to lose. Keeping both is recoverable by
    /// hand; a replaced draft is not.
    static func merged(existing: String, restored: String) -> String {
        let restoredText = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !restoredText.isEmpty else {
            return existing
        }

        let existingText = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingText.isEmpty else {
            return restoredText
        }

        return existingText + "\n\n" + restoredText
    }
}

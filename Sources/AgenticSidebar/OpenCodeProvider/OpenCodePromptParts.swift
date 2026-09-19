import Foundation
import UniformTypeIdentifiers

/// A single element of the `parts` array on the OpenCode prompt endpoint.
///
/// Verified against the OpenCode 1.18.31 server schema: a prompt accepts a union
/// of text and file parts discriminated by `type`, and a file part is
/// `{type: "file", mime: String, filename?: String, url: String}`. The bundled
/// CLI itself inlines attachments as `data:<mime>;base64,<payload>` URLs, so a
/// `data:` URL is a first-class value here rather than an invented shape.
enum OpenCodePromptPart: Encodable, Equatable, Sendable {
    case text(String)
    case file(mime: String, filename: String?, url: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case mime
        case filename
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .file(let mime, let filename, let url):
            try container.encode("file", forKey: .type)
            try container.encode(mime, forKey: .mime)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encode(url, forKey: .url)
        }
    }
}

/// Builds the prompt parts for one user turn.
///
/// The backend keeps the conversation inside its own session, so only the newest
/// user turn is submitted. Attachments that cannot be safely inlined stay
/// referenced by path in the prompt text — the managed agent can read local files
/// itself — so a single oversized or unsupported file never breaks a turn.
///
/// A `file` part is only ever a medium the model layer accepts as an attachment:
/// an image or a PDF. A text document is *quoted into the prompt* instead. That
/// distinction is not cosmetic — sending `{"type":"file","mime":"text/markdown"}`
/// made the provider fail the turn with
/// `'media type: text/markdown' functionality not supported.`, which reached the
/// user as "The provider returned a response this app could not interpret."
/// Worse, the rejected part stayed in the backend session's history, so every
/// later turn of that conversation failed the same way — including ones with no
/// attachment at all.
enum OpenCodePromptBuilder {
    /// The OpenCode CLI refuses local attachments above 10 MiB; the server path
    /// has the same practical limit, so larger files are referenced instead.
    static let maximumInlineAttachmentBytes = 10 * 1024 * 1024

    /// How much of a text attachment is quoted into the prompt.
    ///
    /// Proportional to ``OpenCodeHistoryPreamble/maximumCharacters``: an
    /// attachment is one part of a turn, not the whole context window. A longer
    /// document is referenced by path and the agent reads it with its own tool.
    static let maximumInlineTextCharacters = 64_000

    /// Total quoted-text budget across all attachments in one turn.
    ///
    /// Tek belge sınırı yetmez: beş tane 64k belge tek turda 320k eder ve
    /// bağlamı taşırır. Bütçe dolunca kalan belgeler yola düşer.
    static let maximumQuotedTotalCharacters = 96_000

    static func parts(
        for message: ChatMessage,
        speedMode: ResponseSpeedMode,
        mode: AgentMode = .build,
        historyPreamble: String? = nil,
        fileManager: FileManager = .default,
        maximumInlineBytes: Int = OpenCodePromptBuilder.maximumInlineAttachmentBytes
    ) -> [OpenCodePromptPart] {
        var parts: [OpenCodePromptPart] = []
        var quotedDocuments: [QuotedDocument] = []
        var quotedTotal = 0
        var referencedOnly: [String] = []

        for path in message.attachmentPaths {
            if let part = inlinePart(
                forPath: path,
                fileManager: fileManager,
                maximumInlineBytes: maximumInlineBytes
            ) {
                parts.append(part)
            } else if quotedTotal < maximumQuotedTotalCharacters,
                let document = quotedDocument(
                    forPath: path,
                    fileManager: fileManager,
                    maximumCharacters: min(
                        maximumInlineTextCharacters,
                        maximumQuotedTotalCharacters - quotedTotal
                    )
                )
            {
                quotedTotal += document.text.count
                quotedDocuments.append(document)
            } else {
                referencedOnly.append(path)
            }
        }

        let text = promptText(
            message.text,
            quotedDocuments: quotedDocuments,
            referencedOnly: referencedOnly,
            speedMode: speedMode,
            mode: mode,
            historyPreamble: historyPreamble,
            extensionTags: message.extensionTags
        )
        guard !text.isEmpty else {
            return parts
        }

        return [.text(text)] + parts
    }

    static func inlinePart(
        forPath path: String,
        fileManager: FileManager = .default,
        maximumInlineBytes: Int = OpenCodePromptBuilder.maximumInlineAttachmentBytes
    ) -> OpenCodePromptPart? {
        guard
            let mimeType = inlineMIMEType(forPath: path),
            let attributes = try? fileManager.attributesOfItem(atPath: path),
            let size = SessionArchiveStore.fileSize(from: attributes[.size]),
            size > 0,
            size <= maximumInlineBytes,
            let data = fileManager.contents(atPath: path),
            !data.isEmpty
        else {
            return nil
        }

        return .file(
            mime: mimeType,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            url: "data:\(mimeType);base64,\(data.base64EncodedString())"
        )
    }

    /// Only media the model layer accepts as an attachment becomes a `file` part:
    /// images and PDFs. Text is not one of them — it is quoted into the prompt by
    /// ``quotedDocument(forPath:fileManager:maximumCharacters:)`` — and anything
    /// else (archives, binaries, unknown extensions) is referenced by path, so the
    /// backend never has to reject an unsupported media type.
    static func inlineMIMEType(forPath path: String) -> String? {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard
            !fileExtension.isEmpty,
            let type = UTType(filenameExtension: fileExtension),
            let mimeType = type.preferredMIMEType
        else {
            return nil
        }

        let isSupported = type.conforms(to: .image) || type.conforms(to: .pdf)

        return isSupported ? mimeType : nil
    }

    /// A text attachment small enough to travel inside the prompt.
    ///
    /// This is the path a pasted document takes (``PastedTextAttachment`` spills
    /// long pastes to `readme.md`): the model reads the text in the turn it was
    /// attached to, with no tool call and no permission prompt for a file outside
    /// the project. `nil` means "not text, unreadable, empty, or too long" — all
    /// of which fall back to a path reference.
    static func quotedDocument(
        forPath path: String,
        fileManager: FileManager = .default,
        maximumCharacters: Int = OpenCodePromptBuilder.maximumInlineTextCharacters
    ) -> QuotedDocument? {
        guard isTextAttachment(path: path) else {
            return nil
        }
        // Büyük ikili dosyayı tamamını okuyup sonra elememek için önden ele:
        // alıntı bütçesinin birkaç katından büyük dosya zaten yola düşer.
        if let attributes = try? fileManager.attributesOfItem(atPath: path),
            let size = SessionArchiveStore.fileSize(from: attributes[.size]),
            size > maximumCharacters * 4 + 1024
        {
            return nil
        }
        guard
            let data = fileManager.contents(atPath: path),
            !data.isEmpty,
            !data.contains(0),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumCharacters else {
            return nil
        }

        return QuotedDocument(
            filename: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            text: trimmed
        )
    }

    /// Whether the file at `path` is text the prompt can quote.
    ///
    /// Uzantısız metin dosyaları (`README`, `Dockerfile`, `Makefile`) uzantıya
    /// bakılarak elenemez; içerik denetimi `quotedDocument` içindedir (UTF-8 ve
    /// NUL yok). Burada uzantısız dosya aday sayılır, ikili olduğu içerikte elenir.
    static func isTextAttachment(path: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard !fileExtension.isEmpty else {
            return true
        }
        guard let type = UTType(filenameExtension: fileExtension) else {
            return false
        }

        return type.conforms(to: .text) && !type.conforms(to: .pdf)
    }

    /// One text attachment as it appears inside the prompt.
    struct QuotedDocument: Equatable, Sendable {
        let filename: String
        let path: String
        let text: String
    }

    private static func promptText(
        _ text: String,
        quotedDocuments: [QuotedDocument],
        referencedOnly: [String],
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        historyPreamble: String? = nil,
        extensionTags: [ExtensionTag] = []
    ) -> String {
        var sections: [String] = text.isEmpty ? [] : [text]

        sections.append(contentsOf: quotedDocuments.map(quotedSection))

        if !referencedOnly.isEmpty {
            let list =
                referencedOnly
                .map { "- \($0)" }
                .joined(separator: "\n")

            sections.append(
                """
                Attached files on this machine (read them directly when needed):
                \(list)
                """)
        }

        let body =
            sections
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The backend keeps its own session, so the mode instruction has to ride
        // along with every turn that needs it — there is no system prompt slot.
        // The tagged extensions travel the same way, with the turn they belong to.
        // A restored history travels between them and the new message: the model
        // reads instruction, shared past, then the turn to answer.
        guard !body.isEmpty else {
            return body
        }

        var composed: [String] = []
        if let instruction = mode.instructions(
            speedMode: speedMode,
            extensionContext: extensionTags.turnInstruction
        ),
            !instruction.isEmpty
        {
            composed.append(instruction)
        }
        if let historyPreamble, !historyPreamble.isEmpty {
            composed.append(historyPreamble)
        }
        composed.append(
            """
            <user_turn>
            \(body)
            </user_turn>
            """)
        return composed.joined(separator: "\n\n")
    }

    /// One quoted attachment, fenced so its own markdown cannot be read as part
    /// of the message, and labelled with the path so the agent can still open the
    /// file when it needs more than the quoted text.
    private static func quotedSection(_ document: QuotedDocument) -> String {
        let fence = self.fence(for: document.text)

        return """
            Attached file “\(document.filename)” (\(document.path)):

            \(fence)
            \(document.text)
            \(fence)
            """
    }

    /// A fence longer than any backtick run in the document.
    ///
    /// The common case for a quoted attachment is a pasted `readme.md`, which
    /// almost always contains fenced code of its own. A fixed ```` ``` ```` would
    /// be closed by the document's first fence and the rest of it would read as
    /// the user's own message.
    static func fence(for text: String) -> String {
        // Satır-başı sayımı girintili fence'i kaçırıyordu (`"   ```"` sıfır
        // sayılıyordu); metnin içindeki her backtick koşusu sayılır.
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }

        return String(repeating: "`", count: max(3, longestRun + 1))
    }
}

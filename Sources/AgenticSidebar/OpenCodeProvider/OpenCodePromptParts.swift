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
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .file(mime, filename, url):
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
enum OpenCodePromptBuilder {
    /// The OpenCode CLI refuses local attachments above 10 MiB; the server path
    /// has the same practical limit, so larger files are referenced instead.
    static let maximumInlineAttachmentBytes = 10 * 1024 * 1024

    static func parts(
        for message: ChatMessage,
        speedMode: ResponseSpeedMode,
        mode: AgentMode = .build,
        historyPreamble: String? = nil,
        fileManager: FileManager = .default,
        maximumInlineBytes: Int = OpenCodePromptBuilder.maximumInlineAttachmentBytes
    ) -> [OpenCodePromptPart] {
        var parts: [OpenCodePromptPart] = []
        var referencedOnly: [String] = []

        for path in message.attachmentPaths {
            if let part = inlinePart(
                forPath: path,
                fileManager: fileManager,
                maximumInlineBytes: maximumInlineBytes
            ) {
                parts.append(part)
            } else {
                referencedOnly.append(path)
            }
        }

        let text = promptText(
            message.text,
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
            let size = attributes[.size] as? Int,
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

    /// Only media types the server can forward to a model are inlined. Anything
    /// else (archives, binaries, unknown extensions) is referenced by path so the
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

        let isSupported = type.conforms(to: .image)
            || type.conforms(to: .text)
            || type.conforms(to: .pdf)

        return isSupported ? mimeType : nil
    }

    private static func promptText(
        _ text: String,
        referencedOnly: [String],
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        historyPreamble: String? = nil,
        extensionTags: [ExtensionTag] = []
    ) -> String {
        let body: String
        if referencedOnly.isEmpty {
            body = text
        } else {
            let list = referencedOnly
                .map { "- \($0)" }
                .joined(separator: "\n")

            let composed = """
            \(text)

            Attached files on this machine (read them directly when needed):
            \(list)
            """

            body = text.isEmpty
                ? composed.trimmingCharacters(in: .whitespacesAndNewlines)
                : composed
        }

        // The backend keeps its own session, so the mode instruction has to ride
        // along with every turn that needs it — there is no system prompt slot.
        // The tagged extensions travel the same way, with the turn they belong to.
        // A restored history travels between them and the new message: the model
        // reads instruction, shared past, then the turn to answer.
        guard !body.isEmpty else {
            return body
        }

        var sections: [String] = []
        if
            let instruction = mode.instructions(
                speedMode: speedMode,
                extensionContext: extensionTags.turnInstruction
            ),
            !instruction.isEmpty
        {
            sections.append(instruction)
        }
        if let historyPreamble, !historyPreamble.isEmpty {
            sections.append(historyPreamble)
        }
        sections.append(body)
        return sections.joined(separator: "\n\n")
    }
}

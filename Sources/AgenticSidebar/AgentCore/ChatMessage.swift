import Foundation

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Equatable, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String

    /// Local file paths attached by the user, in selection order.
    let attachmentPaths: [String]
    /// The MCP servers, plugins and skills the user tagged with `@` and `/`.
    /// They are part of the message because they shaped the turn: the transcript
    /// shows what a reply was allowed to reach for.
    let extensionTags: [ExtensionTag]
    let createdAt: Date

    var attachmentPath: String? {
        attachmentPaths.first
    }

    init(
        id: UUID,
        role: Role,
        text: String,
        attachmentPaths: [String],
        createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.extensionTags = []
        self.createdAt = createdAt
    }

    /// Tags arrived after the first archives were written, so an old transcript
    /// still opens: the key is simply absent there.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        attachmentPaths = try container.decode([String].self, forKey: .attachmentPaths)
        extensionTags = try container.decodeIfPresent(
            [ExtensionTag].self,
            forKey: .extensionTags
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    init(
        role: Role,
        text: String
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.attachmentPaths = []
        self.extensionTags = []
        self.createdAt = Date()
    }

    init(
        role: Role,
        text: String,
        attachmentPaths: [String],
        extensionTags: [ExtensionTag] = []
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.extensionTags = extensionTags
        self.createdAt = Date()
    }
}

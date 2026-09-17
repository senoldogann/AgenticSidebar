import Foundation

/// OpenCode `permission.asked` olayının uygulama tarafındaki yapısal hali.
///
/// `permission` alanı araç adıdır (ör. `chatgpt-system_computer_click`).
/// `patterns` onaylanacak girdileri, `always` ise "her zaman izin ver"
/// seçeneğinin kapsayacağı desenleri taşır.
struct OpenCodePermissionRequest: Equatable, Sendable {
    let id: String
    let remoteSessionID: String
    /// The local conversation that issued this request (filled in by the runtime).
    var appSessionID: UUID? = nil
    let toolName: String
    let patterns: [String]
    let alwaysPatterns: [String]
    let detail: String?
    /// Whether the request came from a session the turn did not open — in
    /// practice a subagent the `task` tool delegated to.
    ///
    /// It changes nothing about the decision; it is what the approval prompt has
    /// to say, because "may I read outside this folder?" asked on behalf of a
    /// child session reads very differently from the same question asked by the
    /// agent the user is talking to.
    var isDelegatedSession: Bool = false

    static func make(from properties: [String: Any]) -> OpenCodePermissionRequest? {
        guard
            let id = properties["id"] as? String,
            let sessionID = properties["sessionID"] as? String,
            let toolName = properties["permission"] as? String
        else {
            return nil
        }

        let metadata = properties["metadata"] as? [String: Any] ?? [:]

        return OpenCodePermissionRequest(
            id: id,
            remoteSessionID: sessionID,
            toolName: toolName,
            patterns: stringArray(from: properties["patterns"]),
            alwaysPatterns: stringArray(from: properties["always"]),
            detail: detail(from: metadata, toolName: toolName)
        )
    }

    /// Marks the request as raised by a delegated session, judged against the
    /// session the subscription was opened for.
    func marked(ownedBy ownerSessionID: String) -> OpenCodePermissionRequest {
        var copy = self
        copy.isDelegatedSession = remoteSessionID != ownerSessionID
        return copy
    }

    /// Onay diyaloğunda gösterilecek kısa açıklama; ham metadata dökülmez.
    static func detail(from metadata: [String: Any]) -> String? {
        detail(from: metadata, toolName: nil)
    }

    /// - Parameter toolName: Bilgisayar adımıysa (`computer_*`) koordinat ve
    ///   hedef de eklenir; `nil` ise eski anahtar listesiyle çalışır.
    static func detail(from metadata: [String: Any], toolName: String?) -> String? {
        let preferredKeys = [
            "description",
            "subagent_type",
            "title",
            "command",
            "path",
            "filePath",
            "url",
            "query",
            "name"
        ]

        var parts: [String] = []
        for key in preferredKeys {
            guard
                let value = metadata[key] as? String,
                !value.isEmpty
            else {
                continue
            }
            parts.append("\(key): \(value)")
        }

        if let toolName, ComputerActivityTitle.isComputerTool(toolName) {
            let (title, _) = ComputerActivityTitle.titleAndDetail(tool: toolName, input: metadata)
            if let title, !title.isEmpty {
                parts.insert(title, at: 0)
            }
        }

        guard !parts.isEmpty else {
            return nil
        }

        let joined = parts.joined(separator: "\n")
        return joined.count > maximumDetailLength
            ? String(joined.prefix(maximumDetailLength)) + "…"
            : joined
    }

    /// Araç adını kullanıcıya gösterilecek başlığa çevirir.
    static func title(for toolName: String) -> String {
        let suffix = toolName.hasPrefix(ComputerUseConfiguration.toolPrefix)
            ? String(toolName.dropFirst(ComputerUseConfiguration.toolPrefix.count))
            : toolName

        return switch suffix {
        case "session_authority_start":
            "Grant computer authority"
        case "session_authority_status":
            "Inspect computer authority"
        case "session_authority_end":
            "End computer authority"
        case "computer_health":
            "Check computer readiness"
        case "computer_observe":
            "Observe the screen"
        case "computer_screenshot":
            "Take a screenshot"
        case "computer_pointer_position":
            "Read pointer position"
        case "computer_open_app":
            "Open an app"
        case "computer_focus_app":
            "Focus an app"
        case "computer_move_mouse":
            "Move the pointer"
        case "computer_click":
            "Click"
        case "computer_drag":
            "Drag"
        case "computer_scroll", "computer_scroll_until_visible":
            "Scroll"
        case "computer_type_text":
            "Type text"
        case "computer_press_key":
            "Press a key"
        case "computer_release_inputs":
            "Release held inputs"
        case "computer_wait_for_frontmost":
            "Wait for an app"
        case "computer_wait_for_text":
            "Wait for text"
        case "computer_wait_until_changed":
            "Wait for a change"
        case "computer_run":
            "Run a computer action program"
        default:
            suffix.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func stringArray(from rawValue: Any?) -> [String] {
        (rawValue as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static let maximumDetailLength = 400
}

/// OpenCode izin yanıtının üç sonucu.
///
/// `Codable` çünkü denetim kaydı verilen cevabı saklar. `ProviderGateway`
/// içindeki nötr karşılığı ``ProviderPermissionReply`` ile aynı ham değerleri
/// taşır; dönüşüm sınırda yapılır.
enum OpenCodePermissionReply: String, Codable, Equatable, Sendable {
    case once
    case always
    case reject

    init(_ reply: ProviderPermissionReply) {
        switch reply {
        case .once: self = .once
        case .always: self = .always
        case .reject: self = .reject
        }
    }

    var providerReply: ProviderPermissionReply {
        switch self {
        case .once: return .once
        case .always: return .always
        case .reject: return .reject
        }
    }
}

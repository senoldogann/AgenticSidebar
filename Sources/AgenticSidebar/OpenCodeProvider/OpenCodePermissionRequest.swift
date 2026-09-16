import Foundation

/// OpenCode `permission.asked` olayının uygulama tarafındaki yapısal hali.
///
/// `permission` alanı araç adıdır (ör. `chatgpt-system_computer_click`).
/// `patterns` onaylanacak girdileri, `always` ise "her zaman izin ver"
/// seçeneğinin kapsayacağı desenleri taşır.
struct OpenCodePermissionRequest: Equatable, Sendable {
    let id: String
    let remoteSessionID: String
    let toolName: String
    let patterns: [String]
    let alwaysPatterns: [String]
    let detail: String?

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
            detail: detail(from: metadata)
        )
    }

    /// Onay diyaloğunda gösterilecek kısa açıklama; ham metadata dökülmez.
    static func detail(from metadata: [String: Any]) -> String? {
        let preferredKeys = [
            "description",
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
/// `Codable` çünkü denetim kaydı (``ToolAuditLog``) verilen cevabı saklar.
enum OpenCodePermissionReply: String, Codable, Equatable, Sendable {
    case once
    case always
    case reject
}

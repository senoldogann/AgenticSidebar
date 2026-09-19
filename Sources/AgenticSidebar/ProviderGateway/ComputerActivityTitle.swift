import Foundation

/// Bilgisayar kullanımı (computer-use) araç girdilerini insan cümlesine çevirir.
///
/// Girdi sayılar backend'den `Int` ya da `Double` gelebilir; ikisi de okunur.
/// Çıktı timeline satırı, onay diyaloğu detayı ve HUD üçlüsünde aynıdır, bu
/// yüzden tek kaynaktadır: `OpenCodeStreamNormalizer`, `OpenCodePermissionRequest`
/// ve `FloatingHUDController` buradan beslenir.
enum ComputerActivityTitle {
    /// `chatgpt-system_computer_` öneki; `ComputerUseConfiguration.toolPrefix` ile aynı.
    nonisolated static let toolPrefix = "chatgpt-system_computer_"

    nonisolated static let maximumTypedPreviewLength = 60

    static func titleAndDetail(tool: String, input: [String: Any]) -> (String?, String?) {
        let action = strippedAction(from: tool)
        switch action {
        case "click":
            return ("Click \(coordinate(input))", detailApp(input))
        case "double_click":
            return ("Double-click \(coordinate(input))", detailApp(input))
        case "move_mouse":
            return ("Move \(coordinate(input))", detailApp(input))
        case "mouse_down", "mouse_up":
            return (action == "mouse_down" ? "Press down \(coordinate(input))" : "Release \(coordinate(input))", detailApp(input))
        case "drag":
            return ("Drag \(dragSpan(input))", detailApp(input))
        case "scroll":
            return ("Scroll \(scrollDelta(input))", detailApp(input))
        case "press_key":
            return ("Press \(keyCombo(input))", detailApp(input))
        case "type_text":
            return ("Type \(typedPreview(input))", detailApp(input))
        case "screenshot":
            return ("Screenshot", detailApp(input))
        case "observe":
            return ("Observe screen", detailApp(input))
        case "focus_app", "open_app":
            return ("Focus \(focusedApp(input) ?? "app")", detailApp(input))
        case "run":
            return ("Computer run \(runSummary(input))", detailApp(input))
        case "wait_for_text", "wait_until_changed", "wait_for_frontmost":
            return ("Wait \(waitSummary(input))", detailApp(input))
        case "pointer_position":
            return ("Read pointer", detailApp(input))
        case "release_inputs":
            return ("Release inputs", detailApp(input))
        default:
            let humanized = ProviderActivityDescriptor.humanizedToolName(action)
            return (humanized.isEmpty ? nil : humanized, detailApp(input))
        }
    }

    // MARK: - Girdi okuyucuları

    static func strippedAction(from tool: String) -> String {
        let lowered = tool.lowercased()
        if lowered.hasPrefix(toolPrefix) {
            return String(lowered.dropFirst(toolPrefix.count))
        }
        return lowered
    }

    /// Yalnızca `chatgpt-system_computer_` öneki bilgisayar adımı sayılır.
    /// Çıplak adlar (`run`, `observe`, `screenshot`…) başka provider'lara ait
    /// olabilir; önek şartsız eşleşme onları yanlış türe düşürürdü.
    static func isComputerTool(_ tool: String) -> Bool {
        tool.lowercased().hasPrefix(toolPrefix)
    }

    private static func number(_ value: Any?) -> String? {
        if let int = value as? Int {
            return String(int)
        }
        if let double = value as? Double {
            return double.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(double))
                : String(double)
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.truncatingRemainder(dividingBy: 1) == 0
                ? String(number.intValue)
                : String(double)
        }
        return nil
    }

    private static func coordinate(_ input: [String: Any]) -> String {
        coordinatePair(x: input["x"], y: input["y"]) ?? "…"
    }

    private static func coordinatePair(x: Any?, y: Any?) -> String? {
        guard let x = number(x), let y = number(y) else {
            return nil
        }
        return "(\(x), \(y))"
    }

    private static func dragSpan(_ input: [String: Any]) -> String {
        let from =
            (input["from"] as? [String: Any]).flatMap {
                coordinatePair(x: $0["x"], y: $0["y"])
            } ?? coordinatePair(x: input["fromX"], y: input["fromY"])
        let to =
            (input["to"] as? [String: Any]).flatMap {
                coordinatePair(x: $0["x"], y: $0["y"])
            } ?? coordinatePair(x: input["toX"], y: input["toY"]) ?? coordinate(input)
        guard let from else {
            return to
        }
        return "\(from) → \(to)"
    }

    private static func scrollDelta(_ input: [String: Any]) -> String {
        let vertical = number(input["vertical"])
        let horizontal = number(input["horizontal"])
        switch (vertical, horizontal) {
        case (let v?, let h?) where h != "0":
            return "(\(h), \(v))"
        case (let v?, _):
            return v
        case (_, let h?):
            return h
        default:
            return "…"
        }
    }

    private static func keyCombo(_ input: [String: Any]) -> String {
        var parts = (input["modifiers"] as? [String] ?? []).map(\.capitalized)
        if let key = (input["key"] as? String), !key.isEmpty {
            parts.append(key.uppercased())
        }
        guard !parts.isEmpty else {
            return "key"
        }
        return parts.joined(separator: "+")
    }

    private static func typedPreview(_ input: [String: Any]) -> String {
        guard let text = (input["text"] as? String), !text.isEmpty else {
            return "text"
        }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        let clipped =
            firstLine.count > maximumTypedPreviewLength
            ? String(firstLine.prefix(maximumTypedPreviewLength)) + "…"
            : firstLine
        return "“\(clipped)”"
    }

    private static func focusedApp(_ input: [String: Any]) -> String? {
        ((input["bundleIdentifier"] as? String)
            ?? (input["name"] as? String) ?? (input["app"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runSummary(_ input: [String: Any]) -> String {
        if let actions = input["actions"] as? [[String: Any]], !actions.isEmpty {
            return "\(actions.count) adım"
        }
        return "…"
    }

    private static func waitSummary(_ input: [String: Any]) -> String {
        if let text = (input["text"] as? String), !text.isEmpty {
            let clipped =
                text.count > maximumTypedPreviewLength
                ? String(text.prefix(maximumTypedPreviewLength)) + "…"
                : text
            return "for “\(clipped)”"
        }
        if let ms = number(input["timeoutMs"]) {
            return "\(ms)ms"
        }
        return "…"
    }

    private static func detailApp(_ input: [String: Any]) -> String? {
        focusedApp(input)
    }
}

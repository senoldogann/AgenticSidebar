import Foundation

/// JSON that remembers the order its keys were added in.
///
/// `JSONSerialization` and `Swift.Dictionary` both lose that order, and the
/// OpenCode configuration is order-sensitive in exactly one place that matters:
/// permission rules are evaluated top to bottom and the **last** match wins, so
/// a `deny` written after an `ask` is not the same configuration as the reverse.
/// Rendering the app's configuration through one small writer also means there is
/// a single place that escapes strings, instead of one per file that writes JSON.
indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case object([Member])
    case array([JSONValue])
    case null

    struct Member: Equatable, Sendable {
        let key: String
        let value: JSONValue

        init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    /// Builds an object from ordered pairs.
    static func object(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(members.map { Member($0.0, $0.1) })
    }

    var isEmptyCollection: Bool {
        switch self {
        case let .object(members):
            members.isEmpty
        case let .array(values):
            values.isEmpty
        default:
            false
        }
    }

    var rendered: String {
        var output = ""
        render(into: &output, depth: 0)
        return output
    }

    var data: Data {
        Data(rendered.utf8)
    }

    /// A value carrying an encodable payload, re-read as JSON.
    ///
    /// Used so a definition that is posted to a running server and the same
    /// definition written into the config file can never disagree: they are the
    /// same encoder output.
    init?(encoding value: some Encodable) {
        let encoder = JSONEncoder()
        guard
            let data = try? encoder.encode(value),
            let decoded = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        self = JSONValue(any: decoded)
    }

    init(any: Any) {
        switch any {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as [String: Any]:
            self = .object(value.map { Member($0.key, JSONValue(any: $0.value)) })
        case let value as [Any]:
            self = .array(value.map { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    private func render(into output: inout String, depth: Int) {
        switch self {
        case let .string(value):
            output.append(Self.quoted(value))
        case let .bool(value):
            output.append(value ? "true" : "false")
        case let .int(value):
            output.append(String(value))
        case let .double(value):
            output.append(String(value))
        case .null:
            output.append("null")
        case let .array(values):
            guard !values.isEmpty else {
                output.append("[]")
                return
            }

            output.append("[\n")
            for (index, value) in values.enumerated() {
                output.append(Self.indent(depth + 1))
                value.render(into: &output, depth: depth + 1)
                output.append(index == values.count - 1 ? "\n" : ",\n")
            }
            output.append(Self.indent(depth))
            output.append("]")
        case let .object(members):
            guard !members.isEmpty else {
                output.append("{}")
                return
            }

            output.append("{\n")
            for (index, member) in members.enumerated() {
                output.append(Self.indent(depth + 1))
                output.append(Self.quoted(member.key))
                output.append(": ")
                member.value.render(into: &output, depth: depth + 1)
                output.append(index == members.count - 1 ? "\n" : ",\n")
            }
            output.append(Self.indent(depth))
            output.append("}")
        }
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: depth)
    }

    private static func quoted(_ value: String) -> String {
        var output = "\""
        for character in value {
            switch character {
            case "\"":
                output.append("\\\"")
            case "\\":
                output.append("\\\\")
            case "\n":
                output.append("\\n")
            case "\r":
                output.append("\\r")
            case "\t":
                output.append("\\t")
            default:
                if let scalar = character.unicodeScalars.first,
                   scalar.value < 0x20 {
                    output.append(String(format: "\\u%04x", scalar.value))
                } else {
                    output.append(character)
                }
            }
        }
        output.append("\"")
        return output
    }
}

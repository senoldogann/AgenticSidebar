import Foundation

/// A parsed `SKILL.md`.
///
/// OpenCode reads only `name` and `description` up front and sends those to the
/// model; everything else — including `body` — is loaded when the model asks for
/// the skill. That is why a skill can be installed "for free": the app validates
/// the same two fields OpenCode does, so a skill that would silently fail to
/// appear is rejected at install time instead.
struct SkillManifest: Equatable, Sendable {
    let name: String
    let description: String
    let license: String?
    let compatibility: String?
    let metadata: [String: String]
    /// Everything after the frontmatter, i.e. the instructions themselves.
    let body: String

    static let maximumNameLength = 64
    static let maximumDescriptionLength = 1_024
}

enum SkillManifestError: Error, Equatable, Sendable {
    case missingFrontmatter
    case unterminatedFrontmatter
    case missingName
    case missingDescription
    case nameTooLong
    case descriptionTooLong
    case invalidName
    /// OpenCode requires the directory name to equal the frontmatter `name`.
    case directoryMismatch(directory: String, name: String)
    case emptyBody

    var message: String {
        switch self {
        case .missingFrontmatter:
            "SKILL.md must start with a `---` frontmatter block."
        case .unterminatedFrontmatter:
            "The frontmatter block is never closed with `---`."
        case .missingName:
            "Frontmatter is missing `name`."
        case .missingDescription:
            "Frontmatter is missing `description`."
        case .nameTooLong:
            "`name` is longer than \(SkillManifest.maximumNameLength) characters."
        case .descriptionTooLong:
            "`description` is longer than \(SkillManifest.maximumDescriptionLength) characters."
        case .invalidName:
            "`name` must be lowercase letters, digits and single hyphens."
        case .directoryMismatch(let directory, let name):
            "`name` is “\(name)” but the folder is “\(directory)”; OpenCode requires them to match."
        case .emptyBody:
            "The skill has no instructions after the frontmatter."
        }
    }
}

enum SkillManifestParser {
    /// Parses the frontmatter and body of a `SKILL.md`.
    ///
    /// The frontmatter is the small YAML subset the Agent Skills format uses:
    /// `key: value` lines, optionally quoted, with nested maps indented under a
    /// key. Nested values are read as `key.subkey` so `metadata` survives even
    /// though OpenCode ignores it.
    static func parse(_ markdown: String) throws -> SkillManifest {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
            first == "---" || first == "--- "
        else {
            throw SkillManifestError.missingFrontmatter
        }

        var closingIndex: Int?
        for index in 1..<lines.count
        where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = index
            break
        }

        guard let closingIndex else {
            throw SkillManifestError.unterminatedFrontmatter
        }

        let fields = parseFields(Array(lines[1..<closingIndex]))
        let body = lines[(closingIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let name = fields["name"]?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else {
            throw SkillManifestError.missingName
        }

        guard let description = fields["description"]?.trimmingCharacters(in: .whitespaces),
            !description.isEmpty
        else {
            throw SkillManifestError.missingDescription
        }

        guard name.count <= SkillManifest.maximumNameLength else {
            throw SkillManifestError.nameTooLong
        }

        guard description.count <= SkillManifest.maximumDescriptionLength else {
            throw SkillManifestError.descriptionTooLong
        }

        guard isValidName(name) else {
            throw SkillManifestError.invalidName
        }

        guard !body.isEmpty else {
            throw SkillManifestError.emptyBody
        }

        return SkillManifest(
            name: name,
            description: description,
            license: fields["license"],
            compatibility: fields["compatibility"],
            metadata: fields.filter { $0.key.hasPrefix("metadata.") }
                .reduce(into: [:]) { result, entry in
                    result[String(entry.key.dropFirst("metadata.".count))] = entry.value
                },
            body: body
        )
    }

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`, spelled out so the failure is explainable.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else {
            return false
        }

        var previousWasHyphen = false
        for (index, character) in name.enumerated() {
            if character == "-" {
                if index == 0 || previousWasHyphen {
                    return false
                }
                previousWasHyphen = true
                continue
            }

            guard character.isASCII, character.isLowercase || character.isNumber else {
                return false
            }
            previousWasHyphen = false
        }

        return !previousWasHyphen
    }

    /// A skill whose folder and `name` disagree never loads, so the installer
    /// refuses it rather than writing a file the agent cannot see.
    static func validate(
        _ manifest: SkillManifest,
        directoryName: String
    ) throws {
        guard manifest.name == directoryName else {
            throw SkillManifestError.directoryMismatch(
                directory: directoryName,
                name: manifest.name
            )
        }
    }

    private static func parseFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var currentParent: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            guard let separator = trimmed.firstIndex(of: ":") else {
                continue
            }

            let key = String(trimmed[trimmed.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                continue
            }

            let isIndented = line.first == " " || line.first == "\t"
            if isIndented, let currentParent {
                fields["\(currentParent).\(key)"] = unquoted(value)
                continue
            }

            if value.isEmpty {
                // A mapping follows: remember it so its children can be named.
                currentParent = key
                continue
            }

            currentParent = key
            fields[key] = unquoted(value)
        }

        return fields
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }

        return value
    }
}

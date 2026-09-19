import Foundation

/// A `SKILL.md` found on disk, whether or not it is usable.
struct DiscoveredSkill: Equatable, Sendable, Identifiable {
    /// The folder name, which OpenCode requires to equal the frontmatter `name`.
    let name: String
    let description: String?
    let path: String
    /// True for a skill inside the app's own managed folder.
    let isManaged: Bool
    /// Where it was found, for the list row.
    let locationLabel: String
    /// Why OpenCode will refuse to load it, when it will.
    let validationError: String?

    var id: String { path }

    var isLoadable: Bool {
        validationError == nil
    }
}

/// Discovers skills off the main actor, and only when something changed.
///
/// Discovery used to run synchronously on the main actor (at launch and on every
/// appearance of the extensions screen): it listed each root and then read and
/// parsed every `SKILL.md` in full, so the cost was proportional to the user's
/// whole skill library and was paid on the thread that draws the window — for data
/// that changes only when they edit their own files.
///
/// The cache makes the common case a handful of `stat` calls: an unchanged library
/// returns the previous answer without opening a single file.
actor SkillsCatalogCache {
    private let catalog: SkillsCatalog
    private var fingerprint: [String: Date] = [:]
    private var skills: [DiscoveredSkill] = []
    private var hasScanned = false

    init(catalog: SkillsCatalog) {
        self.catalog = catalog
    }

    func scan() async -> [DiscoveredSkill] {
        let current = catalog.fingerprint()
        if hasScanned, current == fingerprint {
            return skills
        }

        let catalog = self.catalog
        let scanned = await Task.detached(priority: .utility) {
            catalog.scan()
        }.value

        hasScanned = true
        fingerprint = current
        skills = scanned
        return scanned
    }

    /// Drops the cache so the next ``scan()`` re-reads everything. The fingerprint
    /// already covers edits, so this is only for a caller that knows it changed
    /// something without touching the files (tests do this).
    func invalidate() {
        hasScanned = false
        fingerprint = [:]
    }
}

/// One of the places OpenCode looks for skills.
struct SkillRoot: Equatable, Sendable {
    let url: URL
    let isManaged: Bool
    let label: String
}

/// Lists the skills OpenCode would see, including the ones it would reject.
///
/// Reporting the rejects is the point: "I installed it and nothing happened" is
/// the failure mode this avoids, and OpenCode's own rules are the check.
struct SkillsCatalog: Sendable {
    let roots: [SkillRoot]

    private var fileManager: FileManager {
        .default
    }

    init(roots: [SkillRoot]) {
        self.roots = roots
    }

    /// The managed folder plus the user's own global locations, in the order
    /// OpenCode would give them priority.
    static func live() -> SkillsCatalog {
        let home = FileManager.default.homeDirectoryForCurrentUser

        return SkillsCatalog(
            roots: [
                SkillRoot(
                    url: SkillInstaller.defaultRootDirectoryURL(),
                    isManaged: true,
                    label: "Installed by AgenticSidebar"
                ),
                SkillRoot(
                    url: home.appendingPathComponent(".config/opencode/skills", isDirectory: true),
                    isManaged: false,
                    label: "~/.config/opencode/skills"
                ),
                SkillRoot(
                    url: home.appendingPathComponent(".agents/skills", isDirectory: true),
                    isManaged: false,
                    label: "~/.agents/skills"
                ),
                SkillRoot(
                    url: home.appendingPathComponent(".claude/skills", isDirectory: true),
                    isManaged: false,
                    label: "~/.claude/skills"
                ),
            ]
        )
    }

    /// Modified times for every root and every `SKILL.md` under them.
    ///
    /// This is the cheap half of discovery: a stat per folder and per skill file,
    /// with no file read and no parse. Comparing two of these answers "did
    /// anything change?" for a library of hundreds of skills at the cost of a few
    /// hundred stats, which is what makes it safe to call on every appearance
    /// instead of re-reading every file.
    nonisolated func fingerprint() -> [String: Date] {
        var stamps: [String: Date] = [:]
        let fileManager = FileManager.default

        for root in roots {
            stamps[root.url.path] = Self.modificationDate(of: root.url) ?? .distantPast

            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            for entry in entries {
                let isDirectory =
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                guard isDirectory else {
                    continue
                }

                let skillFile = entry.appendingPathComponent("SKILL.md")
                stamps[skillFile.path] = Self.modificationDate(of: skillFile) ?? .distantPast
            }
        }

        return stamps
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Every skill the agent can see, deduplicated by name in root order: a
    /// managed skill wins over one with the same name elsewhere, which matches
    /// the precedence the app writes its own configuration with.
    func scan() -> [DiscoveredSkill] {
        var seen: Set<String> = []
        var found: [DiscoveredSkill] = []

        for root in roots {
            for skill in scan(root: root) where !seen.contains(skill.name) {
                seen.insert(skill.name)
                found.append(skill)
            }
        }

        return found.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func scan(root: SkillRoot) -> [DiscoveredSkill] {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return entries.compactMap { directory -> DiscoveredSkill? in
            let isDirectory =
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else {
                return nil
            }

            return skill(in: directory, root: root)
        }
    }

    private func skill(in directory: URL, root: SkillRoot) -> DiscoveredSkill {
        let name = directory.lastPathComponent
        let skillFileURL = directory.appendingPathComponent("SKILL.md")
        let path = skillFileURL.path

        guard
            let markdown = try? String(contentsOf: skillFileURL, encoding: .utf8)
        else {
            return DiscoveredSkill(
                name: name,
                description: nil,
                path: path,
                isManaged: root.isManaged,
                locationLabel: root.label,
                validationError: "No SKILL.md in this folder."
            )
        }

        do {
            let manifest = try SkillManifestParser.parse(markdown)
            try SkillManifestParser.validate(manifest, directoryName: name)

            return DiscoveredSkill(
                name: manifest.name,
                description: manifest.description,
                path: path,
                isManaged: root.isManaged,
                locationLabel: root.label,
                validationError: nil
            )
        } catch let error as SkillManifestError {
            return DiscoveredSkill(
                name: name,
                description: nil,
                path: path,
                isManaged: root.isManaged,
                locationLabel: root.label,
                validationError: error.message
            )
        } catch {
            return DiscoveredSkill(
                name: name,
                description: nil,
                path: path,
                isManaged: root.isManaged,
                locationLabel: root.label,
                validationError: "SKILL.md could not be read."
            )
        }
    }
}

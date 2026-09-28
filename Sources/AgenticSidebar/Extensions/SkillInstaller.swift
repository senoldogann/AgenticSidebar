import CryptoKit
import Foundation

/// Kurulumun tedarik zinciri reddi: özet uyuşmazlığı ya da onaysız betik.
///
/// `message` durum satırına aynen yazılır; her iki durum da neyin, neden
/// reddedildiğini ve kullanıcının ne yapacağını söyler.
enum SkillInstallSecurityError: Error, Equatable, Sendable {
    /// Kayıtlı özetle indirilen içerik uyuşmuyor: yukarıda sessiz değişim.
    case shaMismatch(skillName: String, expected: String, actual: String)
    /// `scripts/` çalıştırılabilir içerik taşıyor, açık onay yok.
    case scriptsRequireConfirmation(skillName: String, scriptPaths: [String])

    var message: String {
        switch self {
        case .shaMismatch(let name, let expected, let actual):
            "“\(name)” içeriği kayıtlı özetle uyuşmuyor (beklenen \(expected), gelen \(actual)). Kaynak yukarıda değişmiş olabilir; inceleyip yeniden kurun."
        case .scriptsRequireConfirmation(let name, let scripts):
            "“\(name)” çalıştırılabilir betik taşıyor (\(scripts.sorted().joined(separator: ", "))); kurulum onayı bekliyor."
        }
    }
}

/// Installs a skill, and refuses anything OpenCode would silently ignore.
///
/// The files land in the app's own working directory — `.opencode/skills/` under
/// the managed OpenCode folder — which OpenCode discovers as project config. The
/// user's `~/.claude/skills` and `~/.config/opencode/skills` are read for listing
/// but never written to.
struct SkillInstaller: Sendable {
    /// `.opencode/skills` inside the managed OpenCode working directory: a
    /// project-config path OpenCode scans without touching anything of the
    /// user's own.
    static let configDirectoryName = ".opencode"
    static let skillsDirectoryName = "skills"

    let rootDirectoryURL: URL
    let transport: any ExtensionHTTPTransport

    private var fileManager: FileManager {
        .default
    }

    init(
        rootDirectoryURL: URL = SkillInstaller.defaultRootDirectoryURL(),
        transport: any ExtensionHTTPTransport = URLSessionExtensionTransport.live()
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.transport = transport
    }

    static func defaultRootDirectoryURL() -> URL {
        ManagedOpenCodeServerManager.managedWorkingDirectoryURL()
            .appendingPathComponent(configDirectoryName, isDirectory: true)
            .appendingPathComponent(skillsDirectoryName, isDirectory: true)
    }

    /// The folder a skill named `name` is installed into.
    func directoryURL(for name: String) -> URL {
        rootDirectoryURL.appendingPathComponent(name, isDirectory: true)
    }

    /// Fetches, validates and installs one skill.
    ///
    /// - Parameters:
    ///   - expectedSHA256: Biliniyorsa aranan içerik özeti; uyuşmazlık
    ///     kurulumu durdurur (`shaMismatch`). `nil` ise denetim atlanır.
    ///   - allowExecutableScripts: `scripts/` onayı; `false` iken betikli
    ///     beceri yazılmadan reddedilir (`scriptsRequireConfirmation`).
    @discardableResult
    func install(
        skillNamed name: String,
        from reference: GitHubRepositoryReference,
        source: ExtensionSource,
        expectedSHA256: String? = nil,
        allowExecutableScripts: Bool = false
    ) async throws -> SkillRecord {
        let fetcher = GitHubSkillFetcher(transport: transport)
        let fetched = try await fetcher.fetch(skillNamed: name, from: reference)
        return try install(
            fetched: fetched,
            source: source,
            expectedSHA256: expectedSHA256,
            allowExecutableScripts: allowExecutableScripts
        )
    }

    @discardableResult
    func install(
        fetched: FetchedSkill,
        source: ExtensionSource,
        expectedSHA256: String? = nil,
        allowExecutableScripts: Bool = false
    ) throws -> SkillRecord {
        guard let skillFile = fetched.skillFile,
            let markdown = String(data: skillFile.content, encoding: .utf8)
        else {
            throw ExtensionFetchError.notFound
        }

        // Validate before writing anything: a skill that fails these checks never
        // appears in the agent's list, and finding that out from a folder that
        // looks installed is worse than from a refusal.
        let manifest = try SkillManifestParser.parse(markdown)
        try SkillManifestParser.validate(manifest, directoryName: fetched.name)

        // Özet ve betik denetimi yazmadan ÖNCE: reddedilen kurulum diskte iz
        // bırakmaz, kayıt defteri de kirlenmez.
        let digest = Self.contentSHA256(of: fetched.files)
        if let expectedSHA256, expectedSHA256.lowercased() != digest.lowercased() {
            throw SkillInstallSecurityError.shaMismatch(
                skillName: manifest.name,
                expected: expectedSHA256,
                actual: digest
            )
        }
        let scripts = Self.scriptPaths(in: fetched.files)
        if !scripts.isEmpty, !allowExecutableScripts {
            throw SkillInstallSecurityError.scriptsRequireConfirmation(
                skillName: manifest.name,
                scriptPaths: scripts
            )
        }

        let destination = directoryURL(for: fetched.name)
        // Staged in a sibling directory, then swapped into place.
        //
        // The previous version removed the destination with `try?` and then wrote
        // over whatever a failed removal had left behind, so re-installing after a
        // partial failure produced a directory holding a union of two versions —
        // including `scripts/*` the manifest no longer describes, which the agent
        // would run later. A move can only ever leave one version in place.
        let staging = rootDirectoryURL.appendingPathComponent(
            ".staging-\(fetched.name)-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            var written = 0
            // Karma pin yerine yazılan bayt toplamı günlüğe işlenir.
            var totalBytes = 0
            for file in fetched.files {
                let fileURL = try Self.resolvedURL(
                    forRelativePath: file.relativePath,
                    in: staging
                )
                // Yazmadan ÖNCE ara dizinlerde sembolik bağ denetimi: dizin
                // oluştuktan sonraki kontrol, araya plant edilen bağ ile
                // arşiv içeriğini `staging` dışına taşıyabilirdi.
                try Self.assertNoSymlink(
                    in: fileURL.deletingLastPathComponent(),
                    under: staging
                )
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.content.write(to: fileURL, options: .atomic)
                // Yazılan yol sembolik bağ olamaz; varsa kurulum reddedilir.
                if (try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path)) != nil {
                    throw ExtensionFetchError.badResponse
                }
                written += 1
                totalBytes += file.content.count
            }

            try fileManager.createDirectory(
                at: rootDirectoryURL,
                withIntermediateDirectories: true
            )
            try swap(staging, into: destination)

            // Betik klasörü onayla kuruldu; çalıştırılabilir içerik taşıdığı
            // için uyarı günlüğe düşer.
            if !scripts.isEmpty {
                AppLog.extensions.warning(
                    "Installed skill \(manifest.name, privacy: .public) contains scripts/ with user confirmation"
                )
            }
            AppLog.extensions.info(
                "Installed skill \(manifest.name, privacy: .public) (\(written, privacy: .public) files, \(totalBytes, privacy: .public) bytes)"
            )
        } catch {
            // Nothing is left behind for the next discovery to read as a skill.
            try? fileManager.removeItem(at: staging)
            throw error
        }

        return SkillRecord(
            name: manifest.name,
            description: manifest.description,
            isEnabled: true,
            source: source,
            installedAt: Date(),
            path: destination.appendingPathComponent("SKILL.md").path,
            isManaged: true,
            expectedSHA256: digest
        )
    }

    func remove(skillNamed name: String) throws {
        // Kayıt dışı adla çağrı dizin dışına kaçmamalı (`../` gibi).
        guard SkillManifestParser.isValidName(name) else {
            throw ExtensionFetchError.badResponse
        }
        let directory = directoryURL(for: name)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        try fileManager.removeItem(at: directory)
    }

    /// Puts `staging` where `destination` is, replacing any previous version.
    private func swap(_ staging: URL, into destination: URL) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: staging, to: destination)
            return
        }

        // No backup name: the previous version is not wanted afterwards, and the
        // new directory is already complete on disk next to it.
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: staging,
            backupItemName: nil,
            options: []
        )
    }

    /// `parent` yolunun `root` altındaki her bileşeninin sembolik bağ
    /// olmadığını doğrular; biri bile bağ ise kurulum reddedilir.
    static func assertNoSymlink(in parent: URL, under root: URL) throws {
        var current = parent
        let rootPath = root.standardized.path
        while current.standardized.path.hasPrefix(rootPath + "/") || current.standardized.path == rootPath {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ExtensionFetchError.badResponse
            }
            if current.standardized.path == rootPath {
                break
            }
            current = current.deletingLastPathComponent()
        }
    }

    /// Joins a path from a downloaded archive onto the destination, refusing
    /// anything that would escape it.
    static func resolvedURL(
        forRelativePath relativePath: String,
        in destination: URL
    ) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        guard
            !components.isEmpty,
            !relativePath.hasPrefix("/"),
            !components.contains(".."),
            !components.contains("."),
            !components.contains("")
        else {
            throw ExtensionFetchError.badResponse
        }

        return components.reduce(destination) { url, component in
            url.appendingPathComponent(component)
        }
    }

    /// Kurulumun içerik özeti: yola göre sıralı her dosya için
    /// `yol + 0x00 + içerik` baytlarının SHA-256 değeri (hex).
    ///
    /// Sıralama ve ayraç sabittir; aynı dosya kümesi her makinede aynı özeti
    /// verir, dosya adı-içerik eşleşmesi birbirine karışamaz.
    static func contentSHA256(of files: [FetchedSkillFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.content)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Onaya sunulacak çalıştırılabilir listesi (`scripts` ve altı), sıralı.
    static func scriptPaths(in files: [FetchedSkillFile]) -> [String] {
        files.map(\.relativePath)
            .filter { $0 == "scripts" || $0.hasPrefix("scripts/") }
            .sorted()
    }
}

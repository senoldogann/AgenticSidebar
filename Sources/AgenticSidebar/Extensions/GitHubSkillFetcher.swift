import Foundation

struct FetchedSkillFile: Equatable, Sendable {
    /// Path inside the skill folder, e.g. `SKILL.md` or `scripts/run.sh`.
    let relativePath: String
    let content: Data
}

struct FetchedSkill: Equatable, Sendable {
    let name: String
    let repository: String
    let files: [FetchedSkillFile]

    var skillFile: FetchedSkillFile? {
        files.first { $0.relativePath == "SKILL.md" }
    }
}

/// A `owner/repo` pair, optionally with the path to the skill inside it.
struct GitHubRepositoryReference: Equatable, Sendable {
    let owner: String
    let repository: String
    /// Path of the skill folder inside the repository, when the user pointed at
    /// one explicitly.
    let subpath: String?

    var slug: String { "\(owner)/\(repository)" }

    /// Accepts what a user actually pastes: `owner/repo`, a repository URL, or a
    /// deep link into a folder of it.
    static func parse(_ input: String) -> GitHubRepositoryReference? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        for suffix in [".git", "/"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }

        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            return nil
        }

        let owner = parts[0]
        let repository = parts[1]
        guard !owner.isEmpty, !repository.isEmpty else {
            return nil
        }

        let subpath = parts.count > 2 ? parts[2...].joined(separator: "/") : nil
        return GitHubRepositoryReference(
            owner: owner,
            repository: repository,
            subpath: subpath
        )
    }
}

/// Downloads a skill folder from GitHub.
///
/// The public API is used without a token: this is a handful of read-only
/// requests per install, and a token in the environment is honoured when the
/// user happens to have one exported.
struct GitHubSkillFetcher: Sendable {
    static let maximumFileBytes = 512 * 1024
    static let maximumTotalBytes = 4 * 1024 * 1024
    static let maximumFileCount = 40

    /// Dosyalar bu kadar eşzamanlı indirilir. Sıra korunur — sonuçlar kendi
    /// indekslerine yazılır — yalnızca bekleme süresi kısalır.
    static let maximumConcurrentDownloads = 5

    /// Bir kurulumun tamamı için üst sınır. Tek tek isteklerin zaman aşımları
    /// vardı ama toplamda yavaş bir kaynak kurulumu dakikalarca sürükleyebiliyordu.
    static let installDeadline = Duration.seconds(60)

    let transport: any ExtensionHTTPTransport

    init(transport: any ExtensionHTTPTransport = URLSessionExtensionTransport.live()) {
        self.transport = transport
    }

    func fetch(
        skillNamed name: String,
        from reference: GitHubRepositoryReference
    ) async throws -> FetchedSkill {
        let tree = try await tree(of: reference)
        let folder = Self.skillFolder(
            named: name,
            subpath: reference.subpath,
            in: tree
        )

        guard let folder else {
            throw ExtensionFetchError.notFound
        }

        let paths = tree.filter { $0.hasPrefix(folder + "/") }
            .sorted()
            .prefix(Self.maximumFileCount)

        guard !paths.isEmpty else {
            throw ExtensionFetchError.notFound
        }

        let allPaths = Array(paths)
        let deadline = ContinuousClock.now + Self.installDeadline
        var fetched: [FetchedSkillFile?] = Array(repeating: nil, count: allPaths.count)
        var totalBytes = 0

        // Chunked rather than a sliding window: each chunk downloads concurrently
        // and the chunks run in order, so the array the caller receives is exactly
        // the one the sequential loop used to build. Forty files used to be forty
        // round trips one after another, with the per-request timeouts as the only
        // bound on how long that could take.
        for chunkStart in stride(
            from: 0,
            to: allPaths.count,
            by: Self.maximumConcurrentDownloads
        ) {
            let chunk = Array(
                allPaths[chunkStart..<min(chunkStart + Self.maximumConcurrentDownloads, allPaths.count)]
            )

            let downloaded = try await withThrowingTaskGroup(
                of: (Int, FetchedSkillFile).self
            ) { group in
                for (offset, path) in chunk.enumerated() {
                    let index = chunkStart + offset
                    group.addTask { [self] in
                        guard ContinuousClock.now < deadline else {
                            throw ExtensionFetchError.transport
                        }

                        let data = try await rawFile(path: path, in: reference)
                        guard data.count <= Self.maximumFileBytes else {
                            throw ExtensionFetchError.tooLarge
                        }

                        return (
                            index,
                            FetchedSkillFile(
                                relativePath: String(path.dropFirst(folder.count + 1)),
                                content: data
                            )
                        )
                    }
                }

                var collected: [(Int, FetchedSkillFile)] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }

            for (index, file) in downloaded.sorted(by: { $0.0 < $1.0 }) {
                totalBytes += file.content.count
                guard totalBytes <= Self.maximumTotalBytes else {
                    throw ExtensionFetchError.tooLarge
                }

                fetched[index] = file
            }

            guard ContinuousClock.now < deadline else {
                throw ExtensionFetchError.transport
            }
        }

        let files = fetched.compactMap { $0 }
        guard files.count == allPaths.count else {
            throw ExtensionFetchError.badResponse
        }

        guard files.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw ExtensionFetchError.notFound
        }

        return FetchedSkill(name: name, repository: reference.slug, files: files)
    }

    /// Where the skill named `name` lives in the repository.
    ///
    /// Repositories put skills in `skills/<name>/`, `.claude/skills/<name>/`,
    /// `<name>/` or anything else, so the tree decides instead of a guess: the
    /// shallowest folder whose last component matches wins, and a folder listed
    /// under `skills/` breaks a tie.
    static func skillFolder(
        named name: String,
        subpath: String?,
        in tree: [String]
    ) -> String? {
        var folders: Set<String> = []

        for path in tree {
            guard path.hasSuffix("/SKILL.md") else {
                continue
            }
            folders.insert(String(path.dropLast("/SKILL.md".count)))
        }

        if let subpath, !subpath.isEmpty {
            let normalized =
                subpath.hasPrefix("./")
                ? String(subpath.dropFirst(2))
                : subpath
            if folders.contains(normalized) {
                return normalized
            }
            // A subpath may point at the folder itself or one level above it.
            if let match = folders.first(where: {
                $0.hasSuffix("/" + normalized) || $0 == normalized
            }) {
                return match
            }
        }

        let lowered = name.lowercased()
        let matching = folders.filter {
            ($0 as NSString).lastPathComponent.lowercased() == lowered
        }

        return matching.sorted { left, right in
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count

            if leftDepth != rightDepth {
                return leftDepth < rightDepth
            }

            let leftUnderSkills = left.contains("/skills/") || left.hasPrefix("skills/")
            let rightUnderSkills = right.contains("/skills/") || right.hasPrefix("skills/")
            if leftUnderSkills != rightUnderSkills {
                return leftUnderSkills
            }

            return left < right
        }.first
    }

    private func tree(of reference: GitHubRepositoryReference) async throws -> [String] {
        guard
            let base = Self.repositoryBaseURL(
                host: "api.github.com",
                pathPrefix: "repos",
                reference: reference
            ),
            var components = URLComponents(
                url:
                    base
                    .appendingPathComponent("git")
                    .appendingPathComponent("trees")
                    .appendingPathComponent("HEAD"),
                resolvingAgainstBaseURL: false
            )
        else {
            throw ExtensionFetchError.badResponse
        }

        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]

        guard let url = components.url else {
            throw ExtensionFetchError.badResponse
        }

        var headers = ExtensionHTTPHeaders.gitHubAPI
        if let token = ExtensionHTTPHeaders.gitHubToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        let response = try await transport.get(url, headers: headers)
        return try Self.decodeTree(response.data)
    }

    static func decodeTree(_ data: Data) throws -> [String] {
        struct Tree: Decodable {
            struct Entry: Decodable {
                let path: String
                let type: String
            }
            let tree: [Entry]
        }

        do {
            let decoded = try JSONDecoder().decode(Tree.self, from: data)
            return decoded.tree.filter { $0.type == "blob" }.map(\.path)
        } catch {
            throw ExtensionFetchError.badResponse
        }
    }

    private func rawFile(
        path: String,
        in reference: GitHubRepositoryReference
    ) async throws -> Data {
        guard let url = Self.rawFileURL(path: path, in: reference) else {
            throw ExtensionFetchError.badResponse
        }

        return try await transport.get(url, headers: ExtensionHTTPHeaders.rawText).data
    }

    /// A tree path is repository-controlled text. Interpolating it into a URL
    /// string made a space fail the install and let `?` or `#` silently change
    /// which resource was requested; appending encoded segments cannot.
    static func rawFileURL(
        path: String,
        in reference: GitHubRepositoryReference
    ) -> URL? {
        guard
            let owner = rawPathComponent(reference.owner),
            let repository = rawPathComponent(reference.repository),
            var components = URLComponents(string: "https://raw.githubusercontent.com")
        else {
            return nil
        }

        var segments = ["", owner, repository, "HEAD"]
        segments.append(contentsOf: path.split(separator: "/").map(String.init))
        components.path = segments.joined(separator: "/")

        return components.url
    }

    /// `https://<host>/[prefix/]<owner>/<repo>`, with both path segments encoded.
    ///
    /// Used where a URL *string* has to be built (`URL(string:)` does not encode
    /// for us), unlike ``rawFileURL(path:in:)``, which hands raw text to
    /// `URLComponents` and lets it do the encoding in one step.
    static func repositoryBaseURL(
        host: String,
        pathPrefix: String? = nil,
        reference: GitHubRepositoryReference
    ) -> URL? {
        guard
            let owner = encodedPathComponent(reference.owner),
            let repository = encodedPathComponent(reference.repository)
        else {
            return nil
        }

        return URL(
            string: "https://"
                + host
                + "/"
                + (pathPrefix.map { $0 + "/" } ?? "")
                + owner
                + "/"
                + repository
        )
    }

    /// A repository-controlled segment as it goes *into* a URL builder.
    ///
    /// No percent-encoding happens here on purpose: `URLComponents` encodes the
    /// characters that are invalid in a path when it produces the URL, so a
    /// filename containing `?`, `#` or a space ends up requesting that filename
    /// instead of silently changing which resource is asked for. Encoding first
    /// and letting `URLComponents` encode again would turn `%20` into `%2520`.
    /// Only a name that could not be represented at all is refused.
    static func rawPathComponent(_ component: String) -> String? {
        guard
            !component.isEmpty,
            !component.contains(where: { $0.isNewline || $0 == "\u{0}" })
        else {
            return nil
        }

        return component
    }

    /// One path segment, fully percent-encoded — for building a URL *string*.
    static func encodedPathComponent(_ component: String) -> String? {
        guard !component.isEmpty else {
            return nil
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return component.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

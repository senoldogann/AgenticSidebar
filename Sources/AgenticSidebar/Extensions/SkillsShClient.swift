import Foundation

/// One entry of the skills.sh directory.
///
/// `id` is what the directory uses everywhere: `<source>/<skill>`, e.g.
/// `mattpocock/skills/code-review`.
struct SkillsShEntry: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let skillID: String
    let name: String
    let installs: Int
    /// `owner/repo` the skill lives in.
    let source: String

    /// The directory answers with `skillId`, and Swift's synthesised keys would
    /// look for `skillID`. Every search failed on that one letter — a decode
    /// error the store reported as "skills.sh could not be reached", so the whole
    /// skill catalogue looked like an outage.
    private enum CodingKeys: String, CodingKey {
        case id
        case skillID = "skillId"
        case name
        case installs
        case source
    }

    var installsText: String {
        installs.formatted(.number.notation(.compactName))
    }
}

/// Search over the public skills.sh directory.
///
/// The directory is a catalogue, not an installer: it answers *what exists* and
/// where it lives. Fetching the files is `GitHubSkillFetcher`'s job, so a skill
/// from skills.sh and a skill from a git URL go through the same code path.
struct SkillsShClient: Sendable {
    static let searchEndpoint = URL(string: "https://skills.sh/api/search")!

    let transport: any ExtensionHTTPTransport

    init(transport: any ExtensionHTTPTransport = URLSessionExtensionTransport.live()) {
        self.transport = transport
    }

    func search(_ query: String) async throws -> [SkillsShEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        guard
            var components = URLComponents(
                url: Self.searchEndpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw ExtensionFetchError.badResponse
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]

        guard let url = components.url else {
            throw ExtensionFetchError.badResponse
        }

        let response = try await transport.get(url, headers: ["Accept": "application/json"])
        return try Self.decode(response.data)
    }

    /// Split out so the payload can be tested without a network.
    static func decode(_ data: Data) throws -> [SkillsShEntry] {
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).skills
        } catch {
            throw ExtensionFetchError.badResponse
        }
    }

    private struct SearchResponse: Decodable {
        let skills: [SkillsShEntry]
    }
}

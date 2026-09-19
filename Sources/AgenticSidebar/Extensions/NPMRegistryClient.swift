import Foundation

/// One installable plugin, as the catalog shows it.
struct PluginCatalogEntry: Identifiable, Equatable, Sendable {
    /// The npm module name, which is also what OpenCode is told to load.
    let name: String
    let description: String
    let version: String?
    let homepage: String?

    var id: String { name }
}

/// The plugin catalogue: a search over npm.
///
/// There is no separate registry for OpenCode plugins — a plugin *is* an npm
/// module — so the catalogue is npm's own search, asked for modules that mention
/// OpenCode. Nothing here installs: `ExtensionStore.addPlugin` records the module
/// and the agent loads it at its next start, which keeps this client read-only.
struct NPMRegistryClient: Sendable {
    static let searchEndpoint = URL(string: "https://registry.npmjs.org/-/v1/search")!

    /// What the screen shows before the user types anything: the modules the
    /// OpenCode ecosystem actually publishes under.
    static let defaultQuery = "opencode plugin"

    static let pageSize = 20

    let transport: any ExtensionHTTPTransport

    init(transport: any ExtensionHTTPTransport = URLSessionExtensionTransport.live()) {
        self.transport = transport
    }

    func search(_ query: String) async throws -> [PluginCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? Self.defaultQuery : trimmed

        guard
            var components = URLComponents(
                url: Self.searchEndpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw ExtensionFetchError.badResponse
        }

        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "size", value: String(Self.pageSize)),
        ]

        guard let url = components.url else {
            throw ExtensionFetchError.badResponse
        }

        let response = try await transport.get(url, headers: ["Accept": "application/json"])
        return try Self.decode(response.data)
    }

    /// Split out so the payload can be tested without a network.
    static func decode(_ data: Data) throws -> [PluginCatalogEntry] {
        struct Response: Decodable {
            struct Object: Decodable {
                struct Package: Decodable {
                    struct Links: Decodable {
                        let npm: String?
                        let homepage: String?
                        let repository: String?
                    }

                    let name: String
                    let description: String?
                    let version: String?
                    let links: Links?
                }

                let package: Package
            }

            let objects: [Object]
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)

            return decoded.objects.map { object in
                PluginCatalogEntry(
                    name: object.package.name,
                    description: object.package.description?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ") ?? "",
                    version: object.package.version,
                    homepage: object.package.links?.homepage
                        ?? object.package.links?.repository
                        ?? object.package.links?.npm
                )
            }
        } catch {
            throw ExtensionFetchError.badResponse
        }
    }
}

import Foundation

struct ExtensionHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data

    var text: String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

enum ExtensionFetchError: Error, Equatable, Sendable {
    case notFound
    case rateLimited
    case unauthorized
    case transport
    case badResponse
    /// The payload is larger than the installer is willing to write.
    case tooLarge
    case empty

    var message: String {
        switch self {
        case .notFound:
            "Not found."
        case .rateLimited:
            "The service is rate limiting this Mac. Try again in a few minutes."
        case .unauthorized:
            "The service rejected the request. A token may be required."
        case .transport:
            "Could not reach the service."
        case .badResponse:
            "The service returned something unexpected."
        case .tooLarge:
            "The file is too large to install."
        case .empty:
            "Nothing was installed; the source was empty."
        }
    }
}

/// The two calls the extension fetchers need.
///
/// Deliberately narrower than a general HTTP client: everything here is a GET
/// against a public endpoint, and a fake in tests should be able to answer with
/// a dictionary of URLs.
protocol ExtensionHTTPTransport: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> ExtensionHTTPResponse
}

/// Konak değiştiren yönlendirmede `Authorization` başlığını düşürür:
/// `URLSession` ilk isteğin başlıklarını hedefe aynen taşır, belirteç
/// (`GITHUB_TOKEN`) yabancı konağa sızardı.
final class AuthorizationStrippingRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        if redirected.url?.host?.lowercased() != originalHost {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}

struct URLSessionExtensionTransport: ExtensionHTTPTransport {
    static let defaultTimeout: TimeInterval = 30
    /// Tek yanıt için üst sınır. Kurulum toplamı `maximumTotalBytes` ile ayrıca sınırlıdır.
    static let maximumResponseBytes = 5 * 1024 * 1024
    /// Taşıyıcı belirteci yalnızca bu ana bilgisayara gönderir.
    static let gitHubAPIHost = "api.github.com"

    private let session: URLSession
    private let redirectDelegate: AuthorizationStrippingRedirectDelegate?

    init(session: URLSession) {
        self.session = session
        self.redirectDelegate = nil
    }

    private init(session: URLSession, redirectDelegate: AuthorizationStrippingRedirectDelegate) {
        self.session = session
        self.redirectDelegate = redirectDelegate
    }

    static func live() -> Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        // Tanımlama bilgisi ve önbellek kapalı: her kurulum temiz ve izsiz başlar.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = AuthorizationStrippingRedirectDelegate()
        return Self(
            session: URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil),
            redirectDelegate: delegate
        )
    }

    func get(_ url: URL, headers: [String: String]) async throws -> ExtensionHTTPResponse {
        // Belirteç yalnızca API ana bilgisayarına gider; ham içerik ve olası
        // yönlendirme hedeflerine `Authorization` taşınmaz.
        let outgoing: [String: String]
        if url.host?.lowercased() == Self.gitHubAPIHost {
            outgoing = headers
        } else {
            // Başlık adı farklı yazımla gelse bile belirteç sızmaz.
            outgoing = headers.filter { $0.key.lowercased() != "authorization" }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in outgoing {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ExtensionFetchError.badResponse
            }

            switch response.statusCode {
            case 200..<300:
                // Aşırı büyük yanıt belleğe yığılmadan elenir.
                guard data.count <= Self.maximumResponseBytes else {
                    throw ExtensionFetchError.tooLarge
                }
                return ExtensionHTTPResponse(statusCode: response.statusCode, data: data)
            case 401, 403:
                throw ExtensionFetchError.unauthorized
            case 404:
                throw ExtensionFetchError.notFound
            case 429:
                throw ExtensionFetchError.rateLimited
            default:
                throw ExtensionFetchError.badResponse
            }
        } catch let error as ExtensionFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExtensionFetchError.transport
        }
    }
}

/// The identifiers the fetchers send with their requests.
enum ExtensionHTTPHeaders {
    static let gitHubAPI: [String: String] = [
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    ]

    static let rawText: [String: String] = [
        "Accept": "text/plain"
    ]

    static var gitHubToken: String? {
        ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
    }
}

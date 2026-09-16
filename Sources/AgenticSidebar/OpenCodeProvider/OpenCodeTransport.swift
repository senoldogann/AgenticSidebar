import Foundation

/// OpenCode adaptörünün HTTP tipleri, ortak taşıma katmanının tipleridir.
typealias OpenCodeHTTPResponse = HTTPResponse
typealias OpenCodeLineStream = HTTPLineStream

/// OpenCode adaptörünün taşıma sözleşmesi.
///
/// Gereksinimler ortak `ProviderHTTPTransport`'tan gelir; ayrı bir isim olarak
/// kalmasının nedeni tip güvenliği: derleyici böylece OpenAI taşımasının
/// OpenCode istemcisine verilmesini engeller.
protocol OpenCodeTransport: ProviderHTTPTransport {}

/// `URLSession` uygulamasını ortak taşımaya devreder.
struct URLSessionOpenCodeTransport: OpenCodeTransport {
    private let http: URLSessionHTTPTransport

    private init(http: URLSessionHTTPTransport) {
        self.http = http
    }

    /// Uzun süre sessiz kalabilen olay akışı için ayarlanmış bir oturum kurar.
    /// Her çağrı kendi oturumunu açar.
    static func streaming() -> Self {
        Self(http: .streaming())
    }

    func send(_ request: URLRequest) async throws -> OpenCodeHTTPResponse {
        try await http.send(request)
    }

    func stream(_ request: URLRequest) async throws -> OpenCodeLineStream {
        try await http.stream(request)
    }
}

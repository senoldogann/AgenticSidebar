import Foundation

/// OpenAI adaptörünün HTTP tipleri, ortak taşıma katmanının tipleridir.
///
/// Aynı yanıt/akış yapısının her adaptörde yeniden tanımlanması iki kopyanın
/// birbirinden ayrı düşmesine açık kapı bırakıyordu; isimler adaptör tarafında
/// korunur, tip tektir.
typealias OpenAIHTTPResponse = HTTPResponse
typealias OpenAILineStream = HTTPLineStream

/// OpenAI adaptörünün taşıma sözleşmesi.
///
/// Gereksinimler ortak `ProviderHTTPTransport`'tan gelir; ayrı bir isim olarak
/// kalmasının nedeni tip güvenliği: derleyici böylece OpenCode taşımasının
/// OpenAI çalışma zamanına verilmesini engeller.
protocol OpenAITransport: ProviderHTTPTransport {}

/// `URLSession` uygulamasını ortak taşımaya devreder.
struct URLSessionOpenAITransport: OpenAITransport {
    private let http: URLSessionHTTPTransport

    private init(http: URLSessionHTTPTransport) {
        self.http = http
    }

    /// Uzun süre sessiz kalabilen akışlar için ayarlanmış bir oturum kurar. Her
    /// çağrı kendi oturumunu açar; bu süreç genelinde paylaşılan bir nesne
    /// değildir, adı da bunu söyler.
    static func streaming() -> Self {
        Self(http: .streaming())
    }

    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        try await http.send(request)
    }

    func stream(_ request: URLRequest) async throws -> OpenAILineStream {
        try await http.stream(request)
    }
}

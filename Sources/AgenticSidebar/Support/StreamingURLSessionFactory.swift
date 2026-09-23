import Foundation

enum StreamingURLSessionFactory {
    /// Streaming requests can stay quiet for long stretches while a model reasons
    /// or a tool runs. The default 60 s request timeout aborts such streams, so
    /// transport sessions use a much longer request timeout and a bounded resource
    /// lifetime instead.
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        // Bağlantı kesintisinde isteği hemen öldürmek yerine işletim
        // sistemine kuyruklatır: bağlantı dönünce akış kaldığı yerden değil,
        // en baştan kurulur ama kullanıcı `transportFailure` görmeden bekler.
        // Yeniden deneme politikası `URLSessionHTTPTransport` içindedir.
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}

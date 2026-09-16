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
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

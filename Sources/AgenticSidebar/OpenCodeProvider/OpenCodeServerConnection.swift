import Foundation

struct OpenCodeServerConnection: Equatable, Sendable {
    let baseURL: URL
    let username: String
    let password: String

    var authorizationHeader: String {
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }
}

enum OpenCodeServerStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(version: String, baseURL: URL)
}

protocol OpenCodeServerManaging: Sendable {
    func status() async -> OpenCodeServerStatus
    func start() async throws -> OpenCodeServerConnection
    func currentConnection() async -> OpenCodeServerConnection?
    func stop() async
}

protocol OpenCodeExecutableLocating: Sendable {
    func locate() -> URL?
}

protocol OpenCodePortAllocating: Sendable {
    func allocate() throws -> UInt16
}

protocol OpenCodeHealthChecking: Sendable {
    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String
}

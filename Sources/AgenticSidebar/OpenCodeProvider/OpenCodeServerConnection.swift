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
    /// `computerUse` nil değilse sunucu, uygulamanın ürettiği `OPENCODE_CONFIG`
    /// dosyasıyla başlatılır; MCP kaydı ayrıca yapılır.
    ///
    /// İzin seviyesi burada **yoktur**: sunucu her zaman uygulamanın en sıkı
    /// yönlendirme kurallarıyla başlatılır ve seviye her istekte uygulama
    /// tarafında uygulanır. Seviyeyi başlatmaya bağlamak, onu yapılandırma
    /// dosyasına yazmak demekti — ve değiştirmek için arka ucu yeniden başlatmak.
    func start(
        computerUse: ComputerUseConfiguration?
    ) async throws -> OpenCodeServerConnection
    func currentConnection() async -> OpenCodeServerConnection?
    func stop() async
    func workingDirectory() async -> URL?
    /// Parola taşıyan isteklerden önce portun hâlâ bu yöneticinin çocuğuna
    /// ait olduğunu doğrular. Startup'taki dinleyici denetiminin steady-state
    /// karşılığıdır; `false` ise parola yabancı ele geçmesin diye istek
    /// fail-closed düşer. Varsayılan `true` döner, üretim yöneticisi ezer.
    func verifyCurrentListener() async -> Bool
}

extension OpenCodeServerManaging {
    func verifyCurrentListener() async -> Bool {
        true
    }
    func workingDirectory() async -> URL? {
        nil
    }
}

/// Where an `opencode` binary was found, and whether running it is safe.
///
/// The distinction matters for the message the user sees: "not installed" and
/// "installed but writable by another account" are different problems with
/// different fixes, and collapsing them into "not found" sent people looking for
/// a missing binary that was sitting right there.
enum OpenCodeExecutableResolution: Equatable, Sendable {
    case found(URL)
    case notFound
    /// Found, but the file's owner or permissions mean another account could have
    /// replaced it — and it is about to be launched with the server password.
    case untrusted(path: String, reason: String)
}

protocol OpenCodeExecutableLocating: Sendable {
    func resolution() -> OpenCodeExecutableResolution
}

extension OpenCodeExecutableLocating {
    /// The path, when one was found that may be run.
    func locate() -> URL? {
        if case .found(let url) = resolution() {
            return url
        }
        return nil
    }
}

protocol OpenCodePortAllocating: Sendable {
    func allocate() throws -> UInt16
}

protocol OpenCodeHealthChecking: Sendable {
    func waitUntilHealthy(connection: OpenCodeServerConnection) async throws -> String
}

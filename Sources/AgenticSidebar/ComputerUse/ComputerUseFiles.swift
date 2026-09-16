import Foundation

/// Yönetilen OpenCode dizinine yazılan, uygulamanın sahibi olduğu
/// bilgisayar kullanımı dosyaları.
///
/// Kullanıcının `opencode.json` dosyasına dokunulmaz: izin kuralları ve
/// talimatlar ayrı bir `OPENCODE_CONFIG` dosyasında tutulur ve OpenCode
/// yapılandırmaları birleştirir.
enum ComputerUseFiles {
    /// The app's OpenCode configuration. Named for the whole file rather than for
    /// computer use, because computer use is now one contribution to it: MCP
    /// servers, plugins and skill permissions are written by the same writer, and
    /// OpenCode only reads one `OPENCODE_CONFIG`.
    static let configurationFileName = ManagedOpenCodeConfiguration.fileName
    static let instructionsFileName = "computer-use-instructions.md"

    /// OpenCode, izin kurallarında **son eşleşen** kuralı uygular; bu yüzden
    /// sıra anlamlıdır: önce genel `deny`, sonra özel `ask`/`allow`/`deny`.
    /// `chatgpt-system_*` deny kuralı dosya/git/terminal araçlarını modelin
    /// görmesini engeller; `computer_*` ve yetki araçları kullanıcı onayına
    /// bağlanır. `computer_run_js` (full-host JS) bilinçli olarak kapalıdır.
    ///
    /// Bu kurallar uygulamanın yönlendirme kurallarından
    /// (``ToolApprovalPolicy/routedPermissionRules``) **sonra** yazılır ve onları
    /// geçersiz kılar: `Tam erişim` seviyesi bile bu sunucunun JS aracını ya da
    /// dosya/git araçlarını açmaz. `computer_*` kurallarının `ask` kalması
    /// kullanıcıya sorulacağı anlamına gelmez — `Tam erişim` seviyesinde uygulama
    /// gelen isteği otomatik onaylar — ama `Onay iste` ve `Benim için onayla`
    /// seviyelerinde karar kullanıcıya gelir. Kuralların seviyeye bağlı olmaması
    /// bilinçli: seviye her istekte okunur, böylece tur ortasında değiştirilebilir.
    static let permissionRules: [(permission: String, action: String)] = [
        ("chatgpt-system_*", "deny"),
        ("chatgpt-system_computer_*", "ask"),
        ("chatgpt-system_session_authority_*", "ask"),
        ("chatgpt-system_computer_health", "allow"),
        ("chatgpt-system_computer_run_js", "deny")
    ]

    /// Kuralların sırası sözleşmenin parçası: OpenCode son eşleşen kuralı uygular.
    static func permissionRuleMembers() -> [JSONValue.Member] {
        permissionRules.map { JSONValue.Member($0.permission, .string($0.action)) }
    }

    static func configurationJSON(instructionsURL: URL) -> String {
        ManagedOpenCodeConfiguration.rendered(
            instructionPaths: [instructionsURL.path],
            permissionRules: permissionRuleMembers(),
            extensions: .empty
        )
    }

    /// Writes the computer-use instructions and the app's managed OpenCode
    /// configuration, and returns the path to hand to `OPENCODE_CONFIG`.
    @discardableResult
    static func write(
        configuration: ComputerUseConfiguration,
        extensions: ExtensionRuntimeSnapshot = .empty,
        fileManager: FileManager
    ) throws -> URL {
        let directoryURL = configuration.workingDirectoryURL
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let instructionsURL = directoryURL
            .appendingPathComponent(instructionsFileName)
        try instructionsMarkdown().write(
            to: instructionsURL,
            atomically: true,
            encoding: .utf8
        )

        return try ManagedOpenCodeConfiguration.write(
            in: directoryURL,
            instructionPaths: [instructionsURL.path],
            permissionRules: permissionRuleMembers(),
            extensions: extensions
        )
    }

    static func instructionsMarkdown() -> String {
        let serverName = ComputerUseConfiguration.serverName

        return """
        # Computer Use (chatgpt-system)

        Computer Use is enabled through the local `\(serverName)` MCP server. Its
        tools are prefixed with `\(serverName)_`; file, git, terminal and browser
        tools from that server are disabled by policy.

        Required workflow:

        1. Mint an Admin authority lease with
           `\(serverName)_session_authority_start` (`profile: "admin"`,
           `requestedTtlSeconds` up to 3600). Pass the returned `leaseId` as
           `authorityLeaseId` on every other tool call. Leases expire; mint a new
           one when a call fails with AUTHORITY_REQUIRED or AUTHORITY_EXPIRED.
        2. Check readiness with `\(serverName)_computer_health` before the first
           action. `state` must be `"running"`. If it is `"unavailable"` or a TCC
           boolean is false, tell the user which macOS permission (Accessibility
           or Screen Recording) the helper needs instead of retrying.
        3. Observe before acting: `computer_observe` (accessibility tree) and
           `computer_screenshot` (pixels). Prefer semantic targets (role, text,
           label) over raw coordinates, and re-observe after the UI changes.
        4. Use `computer_run` for short multi-step programs. Handle
           COMPUTER_USER_TAKEOVER (the user took control), COMPUTER_STALE_SNAPSHOT
           and COMPUTER_NEEDS_REPLAN by stopping and re-observing.
        5. Each computer action is approved by the user before it runs. Never try
           to work around a denied action; explain what you need instead.
        """
    }

}

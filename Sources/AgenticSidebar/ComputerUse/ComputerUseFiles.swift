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
        # Computer Use (\(serverName))

        Computer Use is enabled through the local `\(serverName)` MCP server. Its
        tools are prefixed with `\(serverName)_`; file, git, terminal and browser
        tools from that server are disabled by policy.

        Workflow & Best Practices:

        1. Authority: Call `\(serverName)_session_authority_start` once per session
           to obtain an Admin authority lease (arguments are optional, defaults to admin profile).
           Pass the returned `leaseId` as `authorityLeaseId` on subsequent computer tool calls.
           Renew only if a call returns AUTHORITY_EXPIRED or AUTHORITY_REQUIRED.
        2. Fast Perception:
           - Call `\(serverName)_computer_observe` to inspect the frontmost
             application, window title, and active accessibility elements.
           - Use `\(serverName)_computer_screenshot` ONLY when visual inspection
             (e.g., Canvas, web graphics, visual verification) is strictly necessary.
             Do NOT request screenshots on every step when UI tree observation suffices.
           - Check `\(serverName)_computer_health` only if a tool fails with an
             unexpected permission error; do not call it before every routine action.
        3. Batch Execution via `computer_run` (HIGHLY RECOMMENDED):
           - Group sequential physical interactions into a single `\(serverName)_computer_run`
             call instead of executing them as separate turn-by-turn tool calls.
           - For example, batch: click target -> type text -> press Return.
           - Pass `finalObservation: "observe"` in `computer_run` to automatically receive
             the updated perception tree in the same turn without an extra round-trip.
        4. Precise Element Grounding:
           - Ground actions using semantic element index from the active observation:
             `target: { by: "index", snapshotId: observation.snapshotId, index: element.index }`.
           - Fall back to `target: { by: "text", text: "..." }` or `target: { by: "ocrText", text: "..." }`.
           - Avoid raw screen coordinates unless canvas/visual targeting is required.
        5. Application Launching & Focus:
           - When opening applications with `\(serverName)_computer_open_app`, always prefer
             providing `bundleIdentifier` (e.g., `com.apple.Safari`, `com.google.Chrome`,
             `com.apple.calculator`, `com.apple.TextEdit`) for instant resolution.
           - You may specify `timeoutMs` up to 60000.
        6. Approvals & Safety:
           - Each computer action program is approved by the user before it runs.
           - Batching multiple actions inside `computer_run` requires only ONE user approval.
           - Never try to work around a denied action; explain what you need instead.
           - If `COMPUTER_USER_TAKEOVER` occurs, stop immediately and yield control.
        """
    }

}

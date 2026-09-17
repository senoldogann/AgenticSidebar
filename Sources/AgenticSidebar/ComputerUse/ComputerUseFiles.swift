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
           - For example, batch: click target -> type text (with bundleIdentifier) -> press Return (with bundleIdentifier).
           - Every `type_text`, `press_key`, `open_app`, `focus_app` and `wait_for_frontmost`
             action REQUIRES `bundleIdentifier` or `name`. A call without one is rejected
             at the schema boundary and never reaches the machine.
           - Pass `finalObservation: "observe"` in `computer_run` to automatically receive
             the updated perception tree in the same turn without an extra round-trip.
           - Hands off while anything runs: do NOT touch the mouse, trackpad or keyboard
             until the result returns. Physical input aborts the run as
             `COMPUTER_USER_TAKEOVER` by design.
        4. Precise Element Grounding:
           - `target.by` is exactly one of `index` | `role` | `text` | `label` | `ocrText` | `point`.
             No other value validates (`.strict()` rejects even one extra key).
           - `index` requires BOTH `snapshotId` (from the latest `computer_observe`) and
             `index`: `target: { by: "index", snapshotId: observation.snapshotId, index: element.index }`.
             Never reuse a snapshot after any action; re-observe first.
           - `role` needs `role` (+ optional `name`, `exact`); `text`/`ocrText` need `text`
             (+ optional `exact`); `label` needs `label` (+ optional `exact`); `point` needs `x` + `y`.
           - Provide EITHER `x`/`y` OR `target` — never both, never neither.
             `retryBudget` is allowed ONLY together with a semantic `target`, never with raw `x`/`y`.
           - To scope a search inside a container, use `within: { by: "index", snapshotId, index }`
             or `within: { by: "role", role, ... }`.
           - Fall back to `target: { by: "text", text: "..." }` or `target: { by: "ocrText", text: "..." }`.
           - Avoid raw screen coordinates unless canvas/visual targeting is required.
        5. Application Launching & Focus:
           - When opening applications with `\(serverName)_computer_open_app`, always prefer
             providing `bundleIdentifier` (e.g., `com.apple.Safari`, `com.google.Chrome`,
             `com.apple.calculator`, `com.apple.TextEdit`) for instant resolution.
           - `bundleIdentifier` or `name` is required, not optional.
           - You may specify `timeoutMs` up to 5000.
        6. Approvals & Safety:
           - The selected tool approval level applies to each request. Full access answers without a prompt.
           - Ask and Approve for me may require user approval, depending on the tool and its arguments.
           - Batching actions inside `computer_run` generates at most one permission request for the program,
             not one per action; Full access answers it automatically when a request is raised.
           - Never try to work around a denied action; explain what you need instead.
           - If `COMPUTER_USER_TAKEOVER` occurs, stop immediately and yield control.
           - Recovery — never retry the identical payload:
             `COMPUTER_PROTOCOL_INVALID` or `Input validation error` -> shrink to ONE action,
             re-observe for a fresh snapshot, fix the schema (selector? `target.by`? `x`/`y`-vs-`target`?)
             and send once; `STALE_SNAPSHOT`/`NEEDS_REPLAN` -> discard the old observation,
             `computer_observe` again and re-ground; `COMPUTER_USER_TAKEOVER` -> stop, tell the user
             physical input aborted the run, and wait.
        """
    }

}

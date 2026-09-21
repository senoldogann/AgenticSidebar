import Foundation

/// How much the agent may do without asking you first.
///
/// The three levels mirror the one decision a coding-agent user expects to make
/// once, globally, instead of per tool: ask me, decide the safe ones for me, or
/// do not ask at all. Changing the level takes effect on the **next** turn —
/// it is captured at turn start, not when the backend starts.
///
/// ## Why the level is not written into the configuration
///
/// OpenCode only raises `permission.asked` for a tool its own configuration marks
/// `ask`; a tool the configuration allows never produces an event. Writing the
/// selected level into the configuration therefore froze it: the file is read
/// when the server starts, so switching level meant restarting the backend and
/// interrupting the turn in flight — and the level you picked while a turn was
/// running did not apply to that turn.
///
/// So the configuration is written **once**, at the strictest level
/// (``routedPermissionRules``), and this type decides what to do with each
/// request that arrives, using the turn's captured level. Every level is then a superset of the same routed set:
/// ``ask`` defers every request to the user, ``approveSafe`` answers the ones it
/// can prove are safe, ``fullAccess`` answers all of them. Nothing has to be
/// rewritten and nothing has to be restarted.
///
/// Two properties keep that honest:
///
/// - Automatic answers are `.once`, never `.always`. `always` is remembered by
///   OpenCode for the rest of the server session, so auto-answering with it would
///   silently defeat a later switch back to a stricter level. `always` is only
///   ever sent because the user clicked it.
/// - The routed configuration is the strictest set the app supports, so no level
///   can be *stricter* than what the config asks about. A level can only loosen;
///   loosening is exactly what this type is for.
enum ToolApprovalPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Shell, network and external-path mutations require approval; scoped
    /// in-folder file edits remain automatic for compatibility.
    case ask
    /// Safe inspection, in-workspace edits and this project's own build/test
    /// commands run; anything outside the folder, unrecognised shell commands and
    /// URL fetches ask.
    case approveSafe
    /// Nothing asks.
    case fullAccess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: "Ask"
        case .approveSafe: "Approve for me"
        case .fullAccess: "Full access"
        }
    }

    /// One line for the picker row.
    var summary: String {
        switch self {
        case .ask:
            "Ask before running commands, touching files outside this folder, or using the network."
        case .approveSafe:
            "Only potentially unsafe actions ask: outside paths, unrecognised shell commands, URL fetches, and computer use."
        case .fullAccess:
            "Shell, edits, fetches, computer use actions and the authority lease run without a prompt. Full-host JavaScript (computer_run_js) stays denied."
        }
    }

    /// The longer explanation shown under the picker.
    var detail: String {
        switch self {
        case .ask:
            "Reads and in-folder edits run without a prompt. Every shell command, every path outside this folder and every network call waits for your decision. A running turn keeps the level it started with; a change applies from the next turn."
        case .approveSafe:
            "Reads, in-folder edits, a limited set of exact inspection commands (git status, git diff, ls, pwd) and exact build and test commands run unattended. Everything else — external paths, other shell commands, webfetch, the authority lease for computer use — asks. A running turn keeps the level it started with; a change applies from the next turn."
        case .fullAccess:
            "No approval is requested for shell commands, edits and fetches, including paths outside this folder — and none for computer use actions or the authority lease either. This answers the requests the agent raises; a `deny` in your own `~/.config/opencode/opencode.json`, and the app's own `deny` for the computer-use file, git, terminal and full-host JavaScript (computer_run_js) tools, still apply — a denied tool is never asked about, so no level can allow it. A running turn keeps the level it started with; a change applies from the next turn."
        }
    }

    var symbolName: String {
        switch self {
        case .ask: "hand.raised.fill"
        case .approveSafe: "checkmark.shield.fill"
        case .fullAccess: "exclamationmark.triangle.fill"
        }
    }

    /// The level in one word, for the composer's control row.
    ///
    /// The composer shows this next to the input field, where a sentence per state
    /// would push the field itself out of the row. ``summary`` and ``detail`` are
    /// for the tooltips and for Settings, which is one link away.
    var compactName: String {
        switch self {
        case .ask: "Ask"
        case .approveSafe: "Approve"
        case .fullAccess: "Full access"
        }
    }

    /// Whether the copy should be tinted as a warning.
    var isUnrestricted: Bool {
        self == .fullAccess
    }

    // MARK: - Runtime answer

    /// Plan aşaması delegasyon yaptırımının tek meşru hedefi: salt-okunur
    /// araştırma alt-ajanı.
    ///
    /// Karşılaştırma birebirdir; büyük-küçük harf ya da boşluk farkı hedefsizlik
    /// gibi işlem görür (fail-closed). Ayrıştırma (`trim`, boşsa `nil`)
    /// istek yapısındadır; burası yalnızca ad eşitliğine bakar.
    static func isResearchDelegationTarget(_ target: String?) -> Bool {
        target == ManagedOpenCodeConfiguration.researchAgentName
    }

    /// The reply for an approval request that reached the app, or `nil` to defer
    /// it to the user.
    ///
    /// `nil` defers to the user; ``ask`` still auto-approves proven in-folder edits.
    /// An automatic answer is `.once`: OpenCode remembers `always` for the rest of
    /// the server session, which would outlive a switch back to a stricter level.
    func automaticReply(
        for toolName: String,
        patterns: [String] = [],
        baseURL: URL = ManagedAppDirectories.openCodeWorkingDirectory()
    ) -> ProviderPermissionReply? {
        switch self {
        case .ask:
            guard
                Self.isFileMutatingTool(toolName),
                !patterns.isEmpty,
                !Self.reachesOutsideWorkingDirectory(patterns, baseURL: baseURL)
            else {
                return nil
            }
            return .once
        case .approveSafe:
            guard
                Self.isSafeWithoutAsking(toolName)
                    || Self.isTrustedShellCommand(toolName: toolName, patterns: patterns, baseURL: baseURL)
            else {
                return nil
            }
            // `edit`/`write`/`patch`/`multiedit` are auto-approved only for
            // in-folder paths. An absolute path, `~` or `../` is an outside
            // write: it must ask even though the tool name alone looks safe.
            // (`external_directory` asking separately is not relied on — the two
            // requests are not ordered.)
            if Self.isFileMutatingTool(toolName) {
                guard !patterns.isEmpty,
                    !Self.reachesOutsideWorkingDirectory(patterns, baseURL: baseURL)
                else {
                    return nil
                }
            }
            return .once
        case .fullAccess:
            // Tam erişimde bilgisayar kullanımı gözetimsiz çalışır: imleç/klavye
            // ve yetki kirası otomatik onaylanır. Tek istisna tam-host
            // JavaScript'tir (`computer_run_js`): yapılandırmada `deny`
            // olduğu için merkeze hiç ulaşmaz, ama savunma derinliği için
            // burada da sorulur.
            if Self.isBlockedComputerTool(toolName) {
                return nil
            }
            return .once
        }
    }

    /// Tools that may run unattended under ``approveSafe``.
    ///
    /// The test is deliberately about **capability, not intent**: a tool that only
    /// observes (reading a file, listing a directory, the screen-diagnostics of
    /// computer use) cannot change this machine, so asking about it only trains
    /// the user to click Allow. File edits are here because in-folder edits are
    /// what the agent is for — but ``automaticReply(for:patterns:)`` still asks
    /// when the request's patterns reach outside the working directory, and paths
    /// outside the folder trip `external_directory` too. Anything that can reach
    /// the network or leave the working directory by nature is *not* here, and is
    /// therefore asked about.
    /// We deliberately do not try to read a shell command and judge it safe — that
    /// judgement is exactly the kind of pattern matching that looks like security
    /// and is not; unrecognised commands ask instead.
    static func isSafeWithoutAsking(_ toolName: String) -> Bool {
        let name = toolName.lowercased()

        let safeIdentifiers: Set<String> = [
            "read", "glob", "grep", "list", "ls", "lsp", "question", "todowrite",
            "edit", "patch", "write", "multiedit",
            // A search cannot change this machine; it can only send a query, and the
            // level that selected this policy selected network searches too.
            "websearch",
        ]

        if safeIdentifiers.contains(name) {
            return true
        }

        // Unscoped tool names (MCP tools, computer use) arrive with the
        // provider's prefix. A bare `hasSuffix` also matches
        // `evil_computer_observe`, so only the exact capability name or the
        // known `chatgpt-system_` prefix counts.
        let safeSuffixes = [
            "computer_health",
            "computer_observe",
            "computer_screenshot",
            "computer_pointer_position",
        ]
        let computerPrefix = "chatgpt-system_"

        return safeSuffixes.contains { suffix in
            name == suffix || name == computerPrefix + suffix
        }
    }

    /// Whether a shell request may run unattended under ``approveSafe``.
    ///
    /// The configuration no longer classifies shell commands (it asks about every
    /// one of them, which is what lets the level change at runtime), so the
    /// judgement happens here. It is a whitelist of *simple* commands, not a
    /// blacklist of dangerous ones:
    ///
    /// - the request must carry the command text, and every command in it must match;
    /// - the text must be one simple command — no `;`, `&&`, `|`, redirection,
    ///   substitution, subshell or newline. Commands must match exact trusted
    ///   patterns (no wildcard globbing) so chained sub-commands cannot run unattended;
    /// - paths must stay inside the working directory, so a trusted read-only
    ///   command cannot be aimed at `~/.ssh/id_rsa` or `/etc` either.
    ///
    /// Everything that fails any of these asks. Asking is the failure mode we want:
    /// a pattern match that looks like security and is not is worse than a prompt.
    static func isTrustedShellCommand(
        toolName: String,
        patterns: [String],
        baseURL: URL = ManagedAppDirectories.openCodeWorkingDirectory()
    ) -> Bool {
        guard isShellToolName(toolName), !patterns.isEmpty else {
            return false
        }

        return patterns.allSatisfy { command in
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                isSingleSimpleCommand(trimmed),
                staysInsideWorkingDirectory(trimmed, baseURL: baseURL)
            else {
                return false
            }
            return trustedCommandPatterns.contains {
                globMatches(pattern: $0, text: trimmed)
            }
        }
    }

    /// OpenCode names the shell tool `bash`; MCP and future providers suffix it or name it `command`, `exec`, `terminal`, etc.
    private static func isShellToolName(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        return name == "bash"
            || name == "shell"
            || name == "command"
            || name == "terminal"
            || name == "exec"
            || name == "run_command"
            || name.hasSuffix("_bash")
            || name.hasSuffix("_shell")
            || name.hasSuffix("_command")
            || name.hasSuffix("_terminal")
            || name.hasSuffix("_exec")
            || name.hasSuffix("_run_command")
    }

    /// Rejects anything that could chain, redirect, substitute or nest commands.
    ///
    /// This is a *syntax* check on purpose: it needs no knowledge of what the
    /// command does, only that it is a single command whose effect is the one the
    /// whitelist matched.
    static func isSingleSimpleCommand(_ command: String) -> Bool {
        let forbidden: Set<Character> = [
            ";", "&", "|", ">", "<", "`", "$", "\n", "\r", "(", ")", "{", "}", "\\",
        ]

        return !command.contains { forbidden.contains($0) }
    }

    /// Whether the tool drives computer use or its authority lease.
    ///
    /// Bu araçlar `ask` ve `approveSafe` seviyelerinde sorar; `fullAccess`
    /// seviyesinde otomatik onaylanır (hariç: `isBlockedComputerTool`).
    static func isComputerUseTool(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        if name.hasPrefix("chatgpt-system_") {
            return true
        }
        if name.hasPrefix("computer_") || name.contains("computer_") {
            return true
        }
        if name.hasPrefix("session_authority_") || name.contains("session_authority") {
            return true
        }
        return false
    }

    /// Tam erişimde bile otomatik onaylanmayan bilgisayar araçları.
    ///
    /// `computer_run_js` tam-host JavaScript çalıştırır: yapılandırma
    /// `deny` ile kapatır, bu denetim ikinci kilittir.
    static func isBlockedComputerTool(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        return name == "computer_run_js"
            || name == "chatgpt-system_computer_run_js"
            || name.hasSuffix("_computer_run_js")
    }

    /// Whether the tool mutates files by nature (`edit` and its aliases).
    private static func isFileMutatingTool(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        return name == "edit"
            || name == "write"
            || name == "patch"
            || name == "multiedit"
            || name.hasSuffix("_edit")
            || name.hasSuffix("_write")
            || name.hasSuffix("_patch")
            || name.hasSuffix("_multiedit")
    }

    /// Whether any approval pattern reaches outside the working directory.
    ///
    /// Patterns for file tools are paths, not commands: each non-empty pattern is
    /// one path. Absolute paths, `~` and `../` leave the folder, so they ask.
    /// In-folder symlinks pointing outside are resolved via canonical paths.
    /// An empty pattern list means nothing to inspect — the caller (`isSafeWithoutAsking`
    /// succeeding with `[]`) keeps its current behaviour and this returns false.
    static func reachesOutsideWorkingDirectory(
        _ patterns: [String],
        baseURL: URL = ManagedAppDirectories.openCodeWorkingDirectory()
    ) -> Bool {
        patterns.contains { Self.isOutsideWorkingDirectory($0, baseURL: baseURL) }
    }

    /// Whether every whitespace-separated token stays inside the working directory.
    ///
    /// The agent's working directory is the app's own OpenCode folder, so a
    /// relative path is fine and an absolute one, a `~` or a `../` is not: those
    /// are the shapes that reach the user's home directory or the filesystem root.
    /// In-directory symlinks pointing outside are checked to prevent escape.
    static func staysInsideWorkingDirectory(
        _ command: String,
        baseURL: URL = ManagedAppDirectories.openCodeWorkingDirectory()
    ) -> Bool {
        let separators = CharacterSet(charactersIn: " \t\"'")
        let tokens = command.components(separatedBy: separators)

        return !tokens.contains { Self.isOutsideWorkingDirectory($0, baseURL: baseURL) }
    }

    /// Tek yolun çalışma dizininin dışına çıkıp çıkmadığı. İki çağıran da
    /// buraya bakar, o yüzden kabuk komutları ile dosya deseni aynı kuralı
    /// görür: mutlak yol, ev-dizini önekleri (`~`, `$HOME`, `$TMPDIR`),
    /// `..` kaçışı ve dışarıyı gösteren (sarkan dahil) sembolik bağlar.
    private static func isOutsideWorkingDirectory(_ raw: String, baseURL: URL) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else {
            return false
        }
        let expanded = Self.expandLeadingDirectoryVariables(trimmed)
        if expanded.hasPrefix("/")
            || expanded.hasPrefix("~")
            || expanded == ".."
            || expanded.split(separator: "/").contains("..")
        {
            return true
        }

        let canonicalBase = baseURL.resolvingSymlinksInPath().path
        let normalizedBase = canonicalBase.hasSuffix("/") ? canonicalBase : canonicalBase + "/"
        let targetURL = baseURL.appendingPathComponent(expanded)
        // Foundation does not resolve ancestor symlinks when the final file
        // does not exist yet. Resolve the nearest existing ancestor first.
        var ancestor = targetURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            // A dangling symlink looks nonexistent to fileExists; it may
            // still redirect a future write outside the approved root.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                return true
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { return true }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var resolvedURL = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolvedURL.appendPathComponent(component)
        }
        let resolvedTarget = resolvedURL.standardizedFileURL.path
        return resolvedTarget != canonicalBase && !resolvedTarget.hasPrefix(normalizedBase)
    }

    /// Baştaki dizin değişkenlerini açar: `~`, `$HOME`/`${HOME}`,
    /// `$TMPDIR`/`${TMPDIR}`. Yalnız önek genişler; komut ortasındaki
    /// değişkenler kabuk işidir, yol denetiminin değil.
    private static func expandLeadingDirectoryVariables(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // `$TMPDIR` sondaki `/` ile gelir, öneke indirgenir.
        var tmpdir = NSTemporaryDirectory()
        while tmpdir.hasSuffix("/") && tmpdir.count > 1 {
            tmpdir.removeLast()
        }
        if path == "~" || path.hasPrefix("~/") {
            return home + path.dropFirst(1)
        }
        for variable in ["$HOME", "${HOME}"] {
            if path == variable || path.hasPrefix(variable + "/") {
                return home + path.dropFirst(variable.count)
            }
        }
        for variable in ["$TMPDIR", "${TMPDIR}"] {
            if path == variable || path.hasPrefix(variable + "/") {
                return tmpdir + path.dropFirst(variable.count)
            }
        }
        return path
    }

    /// Linear glob matcher for the `*`-only patterns in ``trustedCommandPatterns``.
    ///
    /// Hand-rolled rather than `NSRegularExpression` because the patterns are ours
    /// and the text is not: no backtracking blow-up on a command an injected prompt
    /// controls, and no regex syntax that a pattern could accidentally carry.
    static func globMatches(pattern: String, text: String) -> Bool {
        let patternCharacters = Array(pattern)
        let textCharacters = Array(text)

        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int?
        var starTextIndex = 0

        while textIndex < textCharacters.count {
            if patternIndex < patternCharacters.count,
                patternCharacters[patternIndex] == textCharacters[textIndex]
            {
                patternIndex += 1
                textIndex += 1
                continue
            }

            if patternIndex < patternCharacters.count,
                patternCharacters[patternIndex] == "*"
            {
                starIndex = patternIndex
                starTextIndex = textIndex
                patternIndex += 1
                continue
            }

            guard let star = starIndex else {
                return false
            }

            patternIndex = star + 1
            starTextIndex += 1
            textIndex = starTextIndex
        }

        while patternIndex < patternCharacters.count,
            patternCharacters[patternIndex] == "*"
        {
            patternIndex += 1
        }

        return patternIndex == patternCharacters.count
    }

    /// Read-only inspection plus this project's own build and test commands.
    ///
    /// Deliberately absent: anything that deletes, moves, rewrites history or
    /// fetches over the network. `npm run *` is not here — a repository can define
    /// an arbitrary script, and a prompt-injection chain that reached `npm run`
    /// would then reach that script — only the scripts a coding session needs are
    /// named. `swift build`/`swift test` can execute a package manifest, which is
    /// why they are limited to the working directory by
    /// ``staysInsideWorkingDirectory(_:)``.
    static let trustedCommandPatterns: [String] = [
        // Exact commands only: suffix globs admit mutating flags such as --output.
        "git status", "git status --short",
        "git diff", "git diff --stat", "git diff --cached",
        "git log", "git log --oneline -5", "git show",
        "git branch", "git branch --show-current",
        "ls", "ls -la", "pwd",
        "swift build", "swift test", "npm test",
        "npm run build", "npm run test", "npm run lint", "npm run typecheck",
    ]

    // MARK: - Generated configuration

    /// The permission rules the managed server is **always** started with.
    ///
    /// This set does not depend on the selected level, on purpose: it is the
    /// strictest one the app supports, so every level above it is a decision this
    /// type can make at runtime. See the type's documentation.
    ///
    /// Only permission keys OpenCode documents are written (`read`, `edit`,
    /// `glob`, `grep`, `bash`, `task`, `skill`, `lsp`, `question`, `webfetch`,
    /// `websearch`, `external_directory`, `doom_loop`) plus the `*` catch-all.
    /// Inventing keys here would silently do nothing.
    static let routedPermissionRules: [JSONValue.Member] = [
        // The catch-all asks. Every rule below it carves out what is safe to do
        // without a decision in *every* level, and the priority is that a request
        // reaching the app is a request the app is allowed to auto-approve.
        member("*", "ask"),
        member("read", "allow"),
        member("glob", "allow"),
        member("grep", "allow"),
        member("list", "allow"),
        member("lsp", "allow"),
        member("question", "allow"),
        member("todowrite", "allow"),
        member("skill", "ask"),
        // Mutations must reach the app: backend `allow` skips permission.asked
        // and bypasses the workspace/symlink check. The app auto-approves only
        // verified in-folder paths; missing patterns require a user decision.
        // This rule is identical at every level; the turn policy chooses the reply.
        member("edit", "ask"),
        member("write", "ask"),
        member("patch", "ask"),
        member("multiedit", "ask"),
        // Everything else is routed to the app, which answers using the policy
        // captured at the current turn's start.
        member("bash", "ask"),
        member("task", "ask"),
        member("webfetch", "ask"),
        member("websearch", "ask"),
        member("external_directory", "ask"),
        member("doom_loop", "ask"),
    ]

    private static func member(_ key: String, _ action: String) -> JSONValue.Member {
        JSONValue.Member(key, .string(action))
    }
}

import Foundation

/// How much the agent may do without asking you first.
///
/// The three levels mirror the one decision a coding-agent user expects to make
/// once, globally, instead of per tool: ask me, decide the safe ones for me, or
/// do not ask at all. Changing the level takes effect on the **next** tool call —
/// it is read when a decision has to be made, not when the backend starts.
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
/// request that arrives. Every level is then a superset of the same routed set:
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
    /// Every state-changing action is approved by hand.
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
            "Only potentially unsafe actions ask: outside paths, unrecognised shell commands, and URL fetches."
        case .fullAccess:
            "Nothing asks. The agent can run, read, write and fetch without a prompt."
        }
    }

    /// The longer explanation shown under the picker.
    var detail: String {
        switch self {
        case .ask:
            "Reads and in-folder edits run without a prompt. Every shell command, every path outside this folder and every network call waits for your decision. Takes effect on the next tool call, including mid-turn."
        case .approveSafe:
            "Reads, in-folder edits, a limited set of exact inspection commands (git status, git diff, ls, pwd) and exact build and test commands run unattended. Everything else — external paths, other shell commands, webfetch, the authority lease for computer use — asks. Takes effect on the next tool call, including mid-turn."
        case .fullAccess:
            "No approval is requested for anything, including shell commands and paths outside this folder. This answers the requests the agent raises; a `deny` in your own `~/.config/opencode/opencode.json`, and the app's own `deny` for the computer-use file, git, terminal and JavaScript tools, still apply — a denied tool is never asked about, so no level can allow it. Takes effect on the next tool call, including mid-turn."
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

    /// The reply for an approval request that reached the app, or `nil` to defer
    /// it to the user.
    ///
    /// `nil` is the safe answer and the only one ``ask`` ever returns. An
    /// automatic answer is `.once`: OpenCode remembers an `always` for the rest of
    /// the server session, which would outlive a switch back to a stricter level.
    func automaticReply(
        for toolName: String,
        patterns: [String] = []
    ) -> ProviderPermissionReply? {
        switch self {
        case .ask:
            return nil
        case .approveSafe:
            guard
                Self.isSafeWithoutAsking(toolName)
                    || Self.isTrustedShellCommand(toolName: toolName, patterns: patterns)
            else {
                return nil
            }
            return .once
        case .fullAccess:
            return .once
        }
    }

    /// Tools that may run unattended under ``approveSafe``.
    ///
    /// The test is deliberately about **capability, not intent**: a tool that only
    /// observes (reading a file, listing a directory, the screen-diagnostics of
    /// computer use) cannot change this machine, so asking about it only trains
    /// the user to click Allow. Anything that can mutate state, reach the network
    /// or leave the working directory is *not* here, and is therefore asked about.
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
            "websearch"
        ]

        if safeIdentifiers.contains(name) {
            return true
        }

        // Unscoped tool names (MCP tools, computer use) are checked by suffix so
        // `chatgpt-system_computer_observe` matches `computer_observe`.
        let safeSuffixes = [
            "computer_health",
            "computer_observe",
            "computer_screenshot",
            "computer_pointer_position"
        ]

        return safeSuffixes.contains { name.hasSuffix($0) }
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
    static func isTrustedShellCommand(toolName: String, patterns: [String]) -> Bool {
        guard isShellToolName(toolName), !patterns.isEmpty else {
            return false
        }

        return patterns.allSatisfy { command in
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                isSingleSimpleCommand(trimmed),
                staysInsideWorkingDirectory(trimmed)
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
            ";", "&", "|", ">", "<", "`", "$", "\n", "\r", "(", ")", "{", "}", "\\"
        ]

        return !command.contains { forbidden.contains($0) }
    }

    /// Whether every whitespace-separated token stays inside the working directory.
    ///
    /// The agent's working directory is the app's own OpenCode folder, so a
    /// relative path is fine and an absolute one, a `~` or a `../` is not: those
    /// are the shapes that reach the user's home directory or the filesystem root.
    static func staysInsideWorkingDirectory(_ command: String) -> Bool {
        let separators = CharacterSet(charactersIn: " \t\"'")
        let tokens = command.components(separatedBy: separators)

        return !tokens.contains { token in
            guard !token.isEmpty else {
                return false
            }

            let unquoted = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.hasPrefix("/")
                || unquoted.hasPrefix("~")
                || unquoted.contains("../")
                || unquoted == ".."
        }
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
        "npm run build", "npm run test", "npm run lint", "npm run typecheck"
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
        member("skill", "allow"),
        // In-folder edits are what the agent is for; paths outside the working
        // directory still trip `external_directory`, which is left asking. The
        // aliases are named because they are the same capability under other
        // tool names — leaving them to the catch-all would prompt for an edit the
        // user already decided reads-and-edits are fine for.
        member("edit", "allow"),
        member("write", "allow"),
        member("patch", "allow"),
        member("multiedit", "allow"),
        // Everything else is routed to the app, which answers it according to the
        // level selected *at that moment*.
        member("bash", "ask"),
        member("task", "ask"),
        member("webfetch", "ask"),
        member("websearch", "ask"),
        member("external_directory", "ask"),
        member("doom_loop", "ask")
    ]

    private static func member(_ key: String, _ action: String) -> JSONValue.Member {
        JSONValue.Member(key, .string(action))
    }
}

# AgenticSidebar

A native personal macOS agent app: a sidebar-style chat window that runs without a
Dock icon, can be summoned with a global shortcut, optionally reports session
state from the menu bar, and drives either the direct OpenAI Responses API or a
managed local OpenCode server.

## Requirements

- macOS 26 SDK (the package targets `.macOS(.v26)`)
- Xcode 26 / Swift 6.2 or newer toolchain
- Optional: `opencode` on `PATH` or at `/opt/homebrew/bin/opencode` for the
  OpenCode backend

## Build and run

```bash
swift build --product AgenticSidebar    # compile
./script/build_and_run.sh               # build, bundle, sign and launch
./script/build_and_run.sh --logs        # launch and stream process logs
./script/build_and_run.sh --telemetry   # launch and stream subsystem logs
./script/build_and_run.sh --verify      # launch and assert the process is up
```

The script assembles `dist/AgenticSidebar.app` (Dock-less, `LSUIElement`), signs
it with an Apple Development identity when one is available, and otherwise falls
back to ad-hoc signing — ad-hoc signatures make macOS re-prompt for Keychain
access after every rebuild.

## Sessions

Conversations are first class: the sidebar lists them, "New session" starts one, and
each session owns its own turn task, so a background conversation keeps streaming while
you read or type in another one. The list is stored as JSON in
`~/Library/Application Support/AgenticSidebar/sessions.json` with atomic writes, and
an unreadable archive is moved aside as `sessions.corrupt.json` rather than being
discarded or crashing the app.

The activity timeline is stored with the transcript, so the commands a turn ran are
still there — collapsed under "Thinking" — after a relaunch. A turn that was still
running when the app quit is closed on restore rather than left counting up. The
archive stays bounded: the newest 120 activities per conversation are kept, each tool
result is capped at 4,000 characters with the truncation marked, and a timeline whose
message is gone is dropped.

Long conversations are trimmed to a request budget (the newest messages are kept and
the window starts on a user turn); the chat view says how many messages were left out,
and the stored transcript always stays complete.

Streaming hops use bounded channels, so a fast provider cannot turn the UI queue into
unbounded memory growth — the reader is pressed back instead.

## Agent mode and the prompt queue

The composer's mode menu mirrors the speed menu: **Build** is the agentic default, and
**Plan** asks the assistant to investigate read-only and answer with a single `plan`
block. That block is rendered as a document card rather than chat prose, and the only
way forward is the **Approve & Build** bar under it, which flips the session back to
Build mode and hands the plan back as an ordinary user turn. Plan mode is enforced by
instruction, not by a tool-permission change, so the provider's own workflow is left
alone.

A message sent while a turn is running is queued instead of being refused: queued
prompts keep the speed and mode they were sent with, appear as a removable strip above
the composer, drain in order when the turn settles, and survive a cancellation.

Activity rows in the timeline expand into what the tool actually did — a `+`/`-` diff
for a file change, the contents read, or the console output of a command. "Thought for
Ns" is measured, counts up while the turn is still thinking, and stops when it ends.

## Navigating a long conversation

One bar per prompt lives in the left gutter, drawn as a spindle: the bars grow and
drift right toward the middle of the column, and the bar for the prompt being read is
filled with the theme accent. Clicking a bar scrolls that prompt to the top of the
transcript; hovering shows the prompt itself. The column appears once a conversation
has more than one prompt, and the transcript reserves its width so the bars never sit
over the text.

## The composer

One control beside the model holds the two settings that answer the same
question — how hard the model should work on this turn: the **reasoning effort**
(the model's own variants, with the default marked) and **fast mode**. Its chip
reads `XHigh · Fast`. The agent mode (Build / Plan) sits next to it, and the
provider is shown there but chosen in Settings → AI & Models, because it is a
long-lived choice about how the app is wired rather than something to change
mid-sentence. Provider marks are vector paths drawn in-app, so they stay sharp
without an asset catalogue.

Pasting a document does not slow the app down, and neither does switching
between long conversations: the per-keystroke work is bounded to a prefix of the
composer's text and a window at its end, the rail's titles and the activity
anchors are computed once per change rather than once per frame, and a bounded
shared cache keeps markdown parses across conversation switches. See
`docs/verification/2026-09-16-composer-and-transcript-performance.md`.

## Extensions: MCP, plugins and skills

Settings → **MCP & Plugins** is where the agent's reach is decided. It is
organised by what an extension costs the model rather than by what it is:

- **MCP servers** add the schema of every tool they expose to every request, so
  only the ones you switch on are registered. A server that is listed but off is
  silenced by name in the generated configuration (`tools.<name>_* = false`),
  which also covers a server that lives in your own `~/.config/opencode/`
  configuration — that file is read, never edited. A remote server that needs
  OAuth opens its authorization page from its row.
- **Plugins** are npm modules that run inside the agent; they cost nothing until
  they add tools of their own, and the screen says plainly that they are code.
- **Skills** cost one line each: OpenCode advertises only the name and
  description and loads the body when the model asks for it. They can be found
  on [skills.sh](https://skills.sh) and installed from there, or from any
  `owner/repo` plus the skill's folder name. Every `SKILL.md` is validated
  against the rules OpenCode enforces before it is written, so a skill that would
  silently fail to appear is refused with a reason instead.

In the composer, `@` lists the MCP servers and plugins a turn may use and `/`
lists the skills. Choosing one turns the typed token into a chip that rides with
the message; the tag adds a few lines of instruction to that turn only, and an
untagged turn adds nothing.

MCP servers and plugins are loaded when the agent starts, so a change there
applies on the next start — the tab has a **Restart agent** button for exactly
that. Skills are discovered from disk on every appearance.

Because the model's context is the thing being protected, the app writes its own
configuration (`managed-config.json` inside
`~/Library/Application Support/AgenticSidebar/OpenCode/`) and hands it to
OpenCode through `OPENCODE_CONFIG`; OpenCode merges it with the user's own
configuration, and nothing in the user's files is rewritten.

## Tests

```bash
swift test
```

The suite is hermetic apart from `KeychainCredentialStoreTests`, which writes and
deletes its own throwaway item in the login keychain.

## Configuration

- **OpenAI**: the API key is stored in the login Keychain (`com.dogan.AgenticSidebar`,
  account `openai.api-key`) and read at request time. Responses are requested with
  `store: false`, so the transcript stays local.
- **OpenCode**: Settings starts `opencode serve` bound to `127.0.0.1` with a
  randomly generated server password, discovers providers/models/variants from the
  running server, and forwards provider credentials through OpenCode's own auth
  API. The app never downloads or updates the OpenCode binary.
- **Automation**: clipboard and screenshot automation are opt-in. Both ignore
  pasteboard content that applications mark as concealed or transient.
- **Capture privacy**: best effort only. macOS offers no supported API that
  guarantees this window is excluded from system screenshots or third-party
  recorders; see `docs/verification/`.
- **Tool approvals**: one level for every tool — shell commands, edits, the
  network and computer use — chosen in Settings → AI & Models or from the toolbar
  menu in the chat window:
  - **Ask** — reads and in-folder edits run; every shell command, every path
    outside the working folder and every network call waits for your decision.
  - **Approve for me** — safe inspection (`git status`, `ls`, `rg`, `cat` …) and
    this project's own `swift build`/`swift test`/`npm test` commands run
    unattended; anything that can change state, leave the folder or reach the
    network asks.
  - **Full access** — nothing asks. **This is the default**, matching how the app
    behaved before the level existed; two stricter levels are one click away.
    It answers the requests the agent raises; a `deny` in the user's own
    `opencode.json`, and the app's own `deny` for the computer-use file, git,
    terminal and JavaScript tools, still apply — a denied tool is never asked
    about, so no level can allow it.

  The level is applied **per tool call**, not written into the agent's
  configuration, so changing it takes effect on the running agent's next call and
  the prompts already on screen are re-answered with the new level. "Always
  allow" from a prompt is remembered for the session and can be revoked in
  Settings. Automatic approvals are one-shot, so switching back to a stricter
  level is never silently overridden by an earlier auto-answer. A shell command
  only runs unattended when it is a *single* simple command whose paths stay
  inside the working folder — a trusted prefix chained with `&&`, `;`, `|` or a
  redirect asks instead.
- **Audit trail**: every approval the app answers — tool, command or path,
  whether a level, an earlier "Always allow", or you answered it — is appended to
  `~/Library/Application Support/AgenticSidebar/OpenCode/audit.jsonl` (rotated at
  20 MB, kept 5 files, mode `0600`) and shown under Settings → AI & Models →
  Recent tool decisions. With no prompt in the loop on Full access, this file is
  the record of what actually ran.
- **Computer Use**: opt-in in Settings → Computer Use. The app registers the
  local [`chatgpt-system`](https://github.com/senoldogann/chatgpt-system) MCP
  server with the managed OpenCode server (`POST /mcp`) and starts it with
  `--personal-admin --enable-computer-use`; the repository itself is never
  modified. Permission rules and model instructions are written to the app's own
  `computer-use.json`/`computer-use-instructions.md` inside
  `~/Library/Application Support/AgenticSidebar/OpenCode/` and passed through
  `OPENCODE_CONFIG`, so the user's `opencode.json` stays untouched. Only
  `computer_*` and `session_authority_*` tools are exposed: the filesystem, git,
  terminal, browser and full-host JavaScript tools stay denied by the app's own
  rules whatever the tool approval level is, and `computer_*` /`session_authority_*`
  requests are decided by that level like every other tool. The first run needs
  the helper installed once with
  `npm run setup:computer:macos` in the chatgpt-system folder; see
  `docs/verification/2026-09-16-computer-use-integration.md`.

## Documentation

- `docs/superpowers/specs/` — product/architecture specification
- `docs/superpowers/plans/` — milestone implementation plans
- `docs/verification/` — recorded host verification evidence
- `.ai-architect/` — architecture contract and accepted ADRs

## Continuous integration

`.github/workflows/ci.yml` builds and tests on a macOS 26 runner. A runner without
the macOS 26 SDK cannot compile this package.

Both steps run with `-Xswiftc -warnings-as-errors` — the tree is warning-free, and
that is the state worth holding. Superseded pushes are cancelled by a `concurrency`
group, the SwiftPM build is cached, and the single test that touches the real login
keychain skips itself unless `RUN_KEYCHAIN_TESTS=1` is set, so what CI proves is the
hermetic suite. A `swift-format` report runs alongside as advisory output: this
repository has no `.swift-format` yet, so formatting is not a gate.

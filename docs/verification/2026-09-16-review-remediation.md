# Code Review Remediation — 2026-09-16

## Scope

Remediation of the deep code review performed on branch
`feat/chat-ux-streaming-activities-enter`. Reviewed working-tree snapshot:
`69c7be2ba639cb0a54a5f44299c646c806df52ae` (HEAD `808c535`).

**Out of scope in this round:** the permissiveness of the *default* level. Full
local autonomy is an accepted product decision, and the default level is still
Full access; what changed in round 2 (below) is how the level is applied, not how
permissive the default is. The old fail-open wiring — an auto `reply: "always"` —
was replaced, because `always` is remembered by OpenCode for the rest of the
server session and therefore outlived any later change of mind.

## Round 2 — runtime permission levels, audit trail, remaining findings

The approval level used to be written into the agent's configuration, so it froze
at backend start: changing it meant restarting the engine and interrupting the
running turn, and a change made while a turn ran did not apply to that turn. The
configuration now carries one **policy-independent** set of routing rules — the
strictest the app supports — and every request that reaches the app is answered by
the level as it is *at that moment*.

| Area | Change | Evidence |
| --- | --- | --- |
| Configuration | `ManagedOpenCodeConfiguration` has no approval-level parameter: it writes `ToolApprovalPolicy.routedPermissionRules` (`*: ask` plus the read/in-folder-edit carve-outs). Writing the level there is what used to require a restart | `ManagedConfigurationTests`, `ComputerUseFilesTests`, host run (the written `managed-config.json`) |
| Runtime decision | `ToolApprovalPolicy.automaticReply(for:patterns:)` answers each `permission.asked` from the level read at that moment. Automatic answers are `.once`, never `.always` (which OpenCode remembers for the whole server session); `.always` is only sent because the user clicked it | `ToolApprovalPolicyTests` |
| Shell judgement | "Approve for me" classifies the command in the app: a single simple command (`;`, `&&`, `\|`, redirection, substitution, subshell and newline all send it to the user), paths inside the working folder, and a whitelist of inspection/build/test commands (`npm run *` narrowed to build/test/lint/typecheck) | `ToolApprovalPolicyTests` (chained, absolute-path, destructive and unrelated commands) |
| Live switching | No restart when the level changes; the window-toolbar menu (with pending count) and the prompt card both switch it, and the prompts already on screen are re-answered with the new level | `PermissionApprovalCenterTests`, `OpenCodeSettingsTests`, `SettingsStoreTests` |
| Session grants | "Always allow" is remembered app-side for the session, so it survives a backend restart, matches only the same tool *and* the same patterns, and is revocable in Settings | `PermissionApprovalCenterTests` |
| Approval UI | The bar shows the command verbatim (selectable), the tool's family glyph, a level menu, Deny / Allow once / Always allow | host run + `ConversationDetailView` |
| Audit trail | `ToolAuditLog` appends one JSONL line per decision — tool, patterns, detail, *why* (level / earlier grant / you / timeout / cancelled) and the reply — to `OpenCode/audit.jsonl`, 20 MB × 5 rotation, `0600`; Settings lists the last 20 with a Reveal button | `ToolAuditLogTests` |
| Docs | README documents the three levels, the Full-access default, what a level cannot override (a `deny` in the user's own config, and the app's own denies), and the audit file | — |

Remaining findings from the same review:

| Finding | Change | Evidence |
| --- | --- | --- |
| 1.3 loopback race | The child must own the port before the first credentialed request: `LibprocListenerVerifier` reads the child's own socket descriptors; an unproven start terminates the child and retries on a fresh port | `ListenerVerificationTests`, `OpenCodeServerManagerTests.testAStartRefusesToSendCredentialsToAPortTheChildDoesNotOwn` (the counting health checker sees zero attempts) |
| 1.8 mixed skill versions | Installs stage into `.staging-<name>-<uuid>` and `replaceItemAt` into place; a failure leaves the working version untouched and removes the staging directory | `SkillInstallerTests` |
| 1.10 main-actor discovery | `SkillsCatalogCache` scans in a detached task and answers from cache unless the roots' and each `SKILL.md`'s modification times changed; the registry is only rewritten when discovery changed it | `SkillsCatalogCacheTests` (proves the non-read property by making a file unreadable with an unchanged modification date) |
| 1.12 localized screenshots | 30 localized name fragments matched with `contains`, `.jpeg`/`.heic`/`.tiff` accepted, `kMDItemIsScreenCapture` as a name-independent fallback | `ScreenshotNamingTests` (14 languages plus false positives) |
| 1.17 CI gating | `-Xswiftc -warnings-as-errors` on build and test (both targets are warning-free), `concurrency` group, SwiftPM cache, keychain test skips itself unless `RUN_KEYCHAIN_TESTS=1`, advisory `swift-format` report | clean build of app + test target; `387 tests, 1 skipped, 0 failures` |
| 1.11 shortcut default | New installs default to ⇧⌘B (⌘B is "bold" everywhere); a stored choice is never rebound | `GlobalShortcutSpecTests`, `GlobalShortcutPreferenceTests` |

Other findings (1.1, 1.4–1.7, 1.9, 1.13–1.16, 1.18–1.20) are recorded with their
resolutions in `TODO_code-reviewer.md`; 1.2 is the accepted decision above.

## Fixed

| Area | Change | Evidence |
| --- | --- | --- |
| Backend restart | `OpenCodeProcessHandling` exposes `isRunning()`; `status()` reports a dead child as stopped and clears the connection; `start()` discards stale state, relaunches a dead server, and retries a failed health check once on a fresh port | `BackendRestartResilienceTests` (5 tests) |
| Lost remote sessions | Remote sessions are bound to the server connection that owns them and invalidated when it changes; a prompt rejected with an unexpected response recreates the session once and retries on the open event subscription | `BackendRestartResilienceTests`, `OpenCodeProviderRuntimeTests` |
| Clipboard privacy | Pasteboard content marked `ConcealedType`/`TransientType`/`AutoGeneratedType` (and the other community markers) is ignored; the clipboard is tracked while automation is disabled so enabling it never submits stale content; copies that arrive during a turn are queued instead of dropped | `ClipboardMonitorServiceTests` (5 tests) |
| Screenshot automation | Vision OCR moved off the main actor behind `ScreenshotTextRecognizing`; clipboard screenshots are swept after 24 h instead of accumulating; tracked paths bounded; captures during a turn are queued | `ScreenshotMonitorServiceTests` (3 tests) |
| Attachments | `ChatMessage.attachmentPaths` replaces the single path so no selection is dropped; OpenAI inlines local images as `input_image` data URLs and reports unsendable files in text; OpenCode receives attachment paths for its own agent | `PromptAttachmentTests` (4 tests) |
| OpenAI privacy | Requests are sent with `store: false` | `OpenAIResponsesRequestTests`, `PromptAttachmentTests` |
| Error taxonomy | `ProviderRuntimeError.rateLimited` / `AgentSessionError.rateLimited`; HTTP mapping is 401/403 credential, 429 rate limited, 5xx unavailable, other 4xx unexpected response; capability failures now surface the most actionable cause (a missing credential is no longer hidden behind an unrelated outage) | `ProviderHTTPStatusTests`, `SessionFailureTaxonomyTests` |
| Error visibility | Session errors have user-facing messages and are rendered in a banner; the stale "added in later milestones" empty state is gone | `SessionFailureTaxonomyTests`, `ConversationDetailView` |
| Stream robustness | Buffered text deltas are flushed in arrival order at turn completion instead of being discarded; part state is released at turn end; a finished activity no longer overwrites a newer `.waiting` status | `SessionFailureTaxonomyTests`, `OpenCodeStreamNormalizerTests` |
| Long streams | Both transports use a URL session with a 300 s request timeout instead of the 60 s default | — |
| Global shortcut | The show/hide shortcut is a persisted `GlobalShortcutChoice` and is re-registered on change; the Carbon handler hops to the main actor instead of trapping | `GlobalShortcutPreferenceTests` |
| Crash paths | The four `preconditionFailure` sites in the composer and activity timeline now degrade gracefully | — |
| Markdown | `___` terminates a paragraph like the other rules; four-digit line prefixes stay prose; parsing is memoised per text change | `MarkdownBlockParsingTests` (4 tests) |
| Silent failures | Capability discovery, provider HTTP status, turn failure, process escalation, configuration-write and automation failures are logged through `AppLog`; the OpenCode config write no longer swallows errors | — |
| Repo hygiene | `README.md`, `.github/workflows/ci.yml`, `.freebuff/` in `.gitignore`, single build invocation in `script/build_and_run.sh`, `CFBundleShortVersionString`/`CFBundleVersion` in the generated `Info.plist` | build script run verified |

## Also fixed while integrating

- Clipboard payloads are read only after an observed change, so polling does not
  touch clipboard data every 0.4 s.
- Activity titles derived from a tool call with no path are no longer resolved
  against the current directory (the working directory name was reported as if it
  were the analysed file).

## Verification

- `swift build --product AgenticSidebar` → **exit 0**, no warnings
- `swift test` → **132 tests / 0 failures** (101 before this change set)
- `./script/build_and_run.sh bogus` → build, bundle, sign, versioned `Info.plist`
  (non-launching mode; no window was opened)

## Deliberately deferred

- **A blocking format gate.** The repository has no `.swift-format` and the tree
  follows the style by hand; adding `swift-format lint` as a gate would fail every
  build until the whole tree is reformatted, so it runs as an advisory report in
  CI instead.
- **A runtime prompt for edits.** In-folder `edit`/`write`/`patch` are allowed by
  the routing rules in every level (that is the documented level semantics, and
  routing them would double-prompt an out-of-folder edit with
  `external_directory`). Their record therefore comes from the activity timeline,
  not the audit log, and the audit log covers the commands, network calls and
  outside paths.

- **Content-stream back-pressure.** Dropping buffered deltas would corrupt the
  answer, so the event streams stay unbounded; the main-actor blocking that made
  unbounded buffering dangerous was removed instead.
- **`Text(LocalizedStringKey)` for markdown.** Switching to
  `AttributedString(markdown:)` changes rendering and needs visual host review.
- **Per-session configuration.** The spec's "a session may preserve its selected
  configuration independently of the global defaults" still requires multi-session
  support; switching provider mid-conversation therefore starts a fresh OpenCode
  context.
- **OpenCode attachments.** The file-part shape for OpenCode 1.18.31 was not
  verified against its API, so attachment paths are forwarded as prompt text
  rather than inventing a protocol shape.
- **Transcript token budgeting.** Long conversations still resend the whole
  transcript; context-limit failures surface as an unexpected-response error.
- **`supportsSelfCaptureFiltering`.** The capability remains declared, with the
  limitation text now stating explicitly that the app performs no capture of its
  own and applies no self-capture filtering.

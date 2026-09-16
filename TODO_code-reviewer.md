# Code Review — AgenticSidebar (Freebuff Desktop)

Reviewer role: senior code review / security audit. Every finding below is a trackable checkbox with a
stable Task ID. Code snippets are patch-style and ready to apply.

## Context

| Field | Value |
| --- | --- |
| Repository | `/Users/.../AgenticSidebar` (Swift package `AgenticSidebar`) |
| Branch | `feat/chat-ux-streaming-activities-enter` (tip commit `808c535 feat: submit composer on Enter, newline on Shift-Enter`) |
| Working tree | **Dirty and unreviewed-by-git**: 48 modified files (`+6,668 / -1,412`) and 81 untracked entries (68 Swift files). Only 9 commits exist on the branch; the milestone work is largely uncommitted. |
| Language / runtime | Swift 6.3.3 (`swift-driver 1.148.6`), Swift 6 language mode, `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]` |
| Frameworks | SwiftUI, AppKit, Observation, Swift Concurrency (actors / `Mutex`), Carbon HIToolbox hot keys, Security (Keychain), Vision, PDFKit, Swift Charts, OSLog |
| Size | 30,536 lines across 118 source files + 54 test files |
| Scope of review | The whole package as it stands in the working tree; emphasis on the branch's subject matter (streaming chat, activity timeline, composer Enter semantics) plus network, process-launch, extension-install, credential and persistence paths. |
| Out of scope | `.build/`, `dist/`, generated artefacts, the third-party `chatgpt-system` / `opencode` projects themselves. |

### Verification performed for this review (evidence, not claims)

- `swift build --product AgenticSidebar --scratch-path /tmp/as-verify` → **clean build, 0 warnings, 0 errors** under Swift 6 language mode (fresh scratch path, 118 files compiled).
- `swift test --scratch-path /tmp/as-verify --skip KeychainCredentialStoreTests` → **353 tests, 0 failures, 0.87 s**.
- Secret scan over the tree (`sk-…`, `AKIA…`, PEM private keys, quoted passwords) → **no committed credentials**.
- Force-unwrap scan (`try!`, `as!`, `fatalError`, `preconditionFailure`) over `Sources/` → **none**; every `[0]` / `.first!`-style index is guarded by a preceding count or emptiness check (verified at `MarkdownChartView.swift:102`, `AgentActivityTimelineView.swift:355`, `GitHubSkillFetcher.swift:49`, `AgentSessionService.swift:51`, `SessionArchive.swift:126`).
- `KeychainCredentialStoreTests` was **not** executed (it writes to the real login keychain and can raise a GUI prompt); see CR-ITEM-1.17.

## Review Plan

- [x] **CR-PLAN-1.1 [Security Scan]** — *Priority: Critical.* Reviewed: Keychain store, loopback server credentials, process launch/env, skill download + install, extension registry/config writes, clipboard & screenshot automation, tool-permission approval path, provider error surfaces.
  - Result: 1 High (CR-ITEM-1.1) plus 1 policy item **accepted by the author** (CR-ITEM-1.2, allow-all by intent), 5 Medium security-relevant findings (CR-ITEM-1.3 … 1.6, 1.19) and 1 Low (CR-ITEM-1.18, 1.21). No injection, no committed secrets, no path traversal found.
- [x] **CR-PLAN-1.2 [Concurrency & Lifecycle Audit]** — *Priority: High.* Reviewed: `BoundedChannel`, all `Task`/actor boundaries in `AgentSession`, `AgentSessionService` save debounce, `SessionArchiveWriter`, `PermissionApprovalCenter` continuations, `ManagedOpenCodeServerManager` startup/stop, `ExtensionSnapshotBox`, startup wiring in `AgenticSidebarApp.init`.
  - Result: no data races or deadlock paths found; cancellation mishandled during backend startup (CR-ITEM-1.13), unbounded shutdown wait (CR-ITEM-1.15).
- [x] **CR-PLAN-1.3 [Performance Audit]** — *Priority: High.* Reviewed: archive encode/trim loop, streaming flush cadence, markdown parse caching, `TranscriptIndexCache`, composer per-keystroke work, extension discovery, GitHub install request fan-out.
  - Result: 4 Medium findings (CR-ITEM-1.7, 1.9, 1.10 and the CJK/IMe note in 1.14); the hot streaming paths are genuinely bounded and cache-keyed — see CR-POS-4.
- [x] **CR-PLAN-1.4 [Bugs & Data Integrity]** — *Priority: High.* Reviewed: archive bounds/pruning, transcript budget trimming, session restore, prompt queue drain, activity pruning, error wording.
  - Result: 6 Low/Medium findings (CR-ITEM-1.8, 1.12, 1.13, 1.14, 1.16, 1.20). Damaged-data handling is otherwise excellent (CR-POS-7).
- [x] **CR-PLAN-1.5 [Quality, Tests & CI]**
- [x] **CR-PLAN-1.6 [Runtime permission architecture]** — *Priority: High.* The approval level used to be written into the agent's configuration, which froze it at backend start: changing it meant restarting the engine and interrupting the turn in flight. The configuration now carries one policy-independent set of routing rules (`ToolApprovalPolicy.routedPermissionRules`, the strictest the app supports) and every request that reaches the app is answered by the level as it is *at that moment* — so a level change applies to the running agent's next tool call, mid-turn included. Verified by `ToolApprovalPolicyTests` (the level's own answers, the trusted-command whitelist, the routing rules not encoding a level), `OpenCodeServerManagerTests` (the config no longer depends on the level) and `PermissionApprovalCenterTests` (session grants, re-interpreting pending requests).
- [x] **CR-PLAN-1.7 [Decision accountability]** — *Priority: Medium.* Every decision is recorded (see CR-ITEM-1.21's resolution) and the session's "Always allow" grants are visible and revocable in Settings rather than living only inside the server session. — *Priority: Medium.* Reviewed: naming/doc-comment discipline, SOLID boundaries, test hermeticity, CI workflow, build script.
  - Result: 2 findings (CR-ITEM-1.17, 1.21-adjacent); overall quality is high (CR-POS-1 … CR-POS-8).

---

## Review Findings

Findings are ordered by severity. Security items come first.

### High

- [x] **CR-ITEM-1.1 [Permission replies fail open when no handler is installed]**
  - **Severity**: High (latent — production wiring currently installs a handler, so the reachable risk today is a future regression, not an active bypass)
  - **Location**: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProviderRuntime.swift:138-155` (the `else { reply = .always }` at **line 144**); behavior pinned by `Tests/AgenticSidebarTests/OpenCodeProviderRuntimeTests.swift:275-306` (`testWithoutAHandlerPermissionsAreApprovedLikeBefore`).
  - **Resolution (2026-09-16)**: Fixed. A runtime constructed without a handler replies `.reject`, and `OpenCodeProviderRuntimeTests.testWithoutAHandlerPermissionsAreRefused` pins that (the old test that pinned `always` was replaced). The runtime decision path also no longer answers `.always` on its own: automatic approvals are `.once`, and `.always` is only ever sent because the user clicked it.
  - **Description**: When `permissionHandler` is `nil`, every `permission.asked` event is answered with `"always"` — a *persistent* allow for that tool pattern, not a one-shot. The app wires a handler in `AgenticSidebarApp.init` today, but the default is the security control's own failure mode: any future construction path (a preview, a test double, a refactor that drops the closure) silently grants the agent permanent, unprompted tool rights — including `bash` and file edits. The accompanying test asserts this is intended, which converts a bug into a documented invariant.
  - **Recommendation**: Fail closed — answer `.reject` (or `.once` only if a human is provably in the loop) and update the test to assert refusal.
  - **Rationale**: Approval prompts exist precisely for the case where nothing is watching; "no decision surface" must never mean "yes".

- [x] **CR-ITEM-1.2 [The managed backend is started with an allow-all permission policy, created silently]**
  - **Status**: **Accepted by the author (2026-09-16): full local autonomy is the intended default.** Demoted from High to Informational; no code change required for the policy itself. Two follow-ups remain open — (a) the grant should be visible in Settings rather than inferred, and (b) the consequences below should be recorded as a known, deliberate trade-off.
  - **Severity**: Informational (accepted design decision)
  - **Location**: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeServerManager.swift:325-360` (`ensureConfigurationExists`, written once on first start into `~/Library/Application Support/AgenticSidebar/OpenCode/opencode.json`); consumed as the child's `currentDirectoryURL` project config in `start()` (line 118).
  - **Resolution (2026-09-16)**: Kept as the accepted decision. Both follow-ups are done: Settings → AI & Models names the effective level, shows the rules file it writes and the exact path (`Reveal` opens it), and the README states that Full access is the default and that `bash`, in-folder `edit` and `external_directory` do not prompt. The README also records what the level does *not* override (the app's own `deny` for computer-use JS and file/git tools).
  - **Description (kept for the record)**: The app creates a default config that grants `"read"`, `"bash"`, `"edit"`, `"glob"`, `"grep"`, `"list"`, `"external_directory"`, `"todowrite"`, `"webfetch"`, `"websearch"` all `"allow"`. Shell execution, file mutation anywhere on the host (`external_directory: allow`) and network fetches therefore proceed with no approval prompt. Combined with the app's input surfaces — web search results, `webfetch` content, auto-submitted clipboard text, screenshots OCR'd from any window, third-party MCP tool output — a prompt-injection chain reaches arbitrary command execution as the user with nothing in between. **The author has confirmed this is intentional**, so the review records it as a deliberate trade-off rather than a defect. What follows from it is scope, not correction:
    - The permission-approval surface (`PermissionApprovalCenter`, its tests, the Deny / Allow once / Always allow bar) is effectively **unreachable for the built-in tools** under this policy — it only ever fires for tools the policy does not allow, i.e. today the `chatgpt-system_*` computer-use tools. That is not a bug, but the UI (and its test suite) reads as a general safety net while covering one provider's tool family. Worth stating in the README/Settings so the guarantee is not over-read.
    - With no prompt in the loop, a local audit trail becomes the only means of answering "what did it actually run?" after the fact (see CR-ITEM-1.21).
  - **Remaining recommendations (Low)**: (a) Surface the effective policy in Settings next to its file path, so the grant is an explicit, inspectable decision rather than an inferred one; (b) state in the README that the default is full local autonomy and that `bash`/`edit`/`external_directory` do not prompt; (c) if upstream OpenCode's own default is `ask`, document the deliberate delta so a future reader does not "fix" it.

### Medium

- [x] **CR-ITEM-1.3 [Server credentials can be delivered to whatever process wins the loopback port race]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProcessLauncher.swift:55-92` (`SystemOpenCodePortAllocator.allocate()` binds port 0, reads it, closes the socket); `OpenCodeServerManager.swift:136-186` (port allocated, then the child is launched and `OpenCodeServerConnection.authorizationHeader` is sent to `http://127.0.0.1:<port>` by the health check at `OpenCodeServerManager.swift:376-425`).
  - **Resolution (2026-09-16)**: Fixed. The child must be the process holding the loopback port before the first request that carries the password: `LibprocListenerVerifier` reads the child's own descriptors (`proc_pidinfo`/`proc_pidfdinfo`) and reports the TCP ports in `LISTEN` state. A start that cannot prove ownership terminates the child and retries on a fresh port instead of sending credentials. `ListenerVerificationTests` covers the socket check against real sockets; `OpenCodeServerManagerTests.testAStartRefusesToSendCredentialsToAPortTheChildDoesNotOwn` asserts the credentialed health request is never sent (the counting health checker sees zero attempts).
  - **Description**: The port is discovered by probing and then *released* before the child binds it (the code comment acknowledges the race and retries once on a fresh port). Any local process that binds the freed port first becomes the peer for a request that carries `Basic base64("opencode:<keychain password>")`. The health check then accepts any `200 {"healthy":true,"version":"…"}`, so an impostor only has to answer plausibly. **Calibration**: a process already running as the same user is not escalated by this — it can run shell commands itself. What makes it worth fixing is the combination with CR-ITEM-1.2: a process that *cannot* currently reach the user's files (a sandboxed helper, an App Store app, a compromised browser renderer) can bind the freed port, harvest the password, and then drive the OpenCode HTTP API — during which it holds process credentials and TCC permissions it would otherwise never have, and the app's own transcript will attribute the resulting commands to the user's agent.
  - **Recommendation**: Prove peer identity before sending the secret. Cheapest options: (a) bind the listening socket in-process and hand the *file descriptor* to the child (`posix_spawn` file-action) so no race exists; (b) keep probing but require the child to echo a per-launch nonce that the app generates and passes via env (never via argv); (c) after health-check success, verify via `libproc`/`lsof` that the PID owning the port is the child `processIdentifier`, and abort otherwise. Option (c) is the smallest change; option (a) is the correct one.

- [x] **CR-ITEM-1.4 [The backend child inherits the entire parent environment]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProcessLauncher.swift:98-130`
  - **Resolution (2026-09-16)**: Fixed earlier in this session: `FoundationOpenCodeProcessLauncher.childEnvironment` allow-lists the variables the backend needs (`PATH`, `HOME`, `TMPDIR`, `XDG_*`, …) instead of inheriting the app's whole environment, and the child's output goes to a truncated `opencode-server.log` in the managed directory rather than `/dev/null`, so a startup crash is readable.
  - **Description**: `process.environment = ProcessInfo.processInfo.environment.merging(request.environment, …)` hands the child every variable the app's process has — including whatever the user exported into their session (`GITHUB_TOKEN`, cloud credentials, proxy passwords) and, by extension, everything a plugin or MCP server spawned by that child can read and forward to a model. Nothing requires this: the app already forwards provider credentials through OpenCode's own auth API, so the general environment is pure surplus exposure. Additionally `standardOutput`/`standardError` are routed to `FileHandle.nullDevice`, so a crash on startup is invisible even though `AppLog` is used elsewhere for exactly that purpose.
  - **Recommendation**: Pass an allow-list (`PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_ALL`, `USER`, `SHELL`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`) merged with the explicit request environment; redirect stderr to a bounded log file under the managed OpenCode directory and log its tail on startup failure.

- [x] **CR-ITEM-1.5 [The backend executable is resolved and launched without an ownership/permission check]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProcessLauncher.swift:22-52` (`SystemOpenCodeExecutableLocator.locate()`), launched at `OpenCodeProcessLauncher.swift:98-130`.
  - **Resolution (2026-09-16)**: Fixed earlier in this session: `SystemOpenCodeExecutableLocator.trust(of:)` refuses a binary that is group/other-writable, is not a regular file, or is owned by another user, and the Settings screen reports the refusal with the path and the reason instead of silently falling through to a different binary.
  - **Description**: Candidate order is `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`. `/usr/local/bin` is commonly admin-writable and frequently *ahead of* the user's intended binary, and nothing verifies the resolved file's owner, mode, or signature before it is executed with the server password and (currently) the full environment. A binary placed in that directory is executed on the next start with the user's privileges. The README correctly states the app never downloads or updates OpenCode — but it will happily run whatever it finds there.
  - **Recommendation**: Before launch, `attributesOfItem` the resolved URL and refuse (with a Settings-surfaced reason) when the file is group/other-writable or owned by neither `root` nor the current user; prefer the user's `PATH` entry over a fixed `/usr/local/bin` when both exist, or expose the resolved path in Settings so it can be seen and overridden.

- [x] **CR-ITEM-1.6 [Repository-controlled path components are pasted into URLs instead of being encoded]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/Extensions/GitHubSkillFetcher.swift:225-235` (`rawFile`), `GitHubSkillFetcher.swift:20-88` (`GitHubRepositoryReference.parse` at line 31, which accepts any characters in `owner`/`repository`), `GitHubSkillFetcher.swift:194-200` (tree URL assembled from the same inputs).
  - **Resolution (2026-09-16)**: Fixed. Repository-controlled text is no longer interpolated into URL strings: the tree URL is built with encoded segments and the raw-file URL hands raw segments to `URLComponents`, which encodes once (pre-encoding would double-encode `%`). The full-install test pins the tree URL, which is what caught the missing `/repos/` segment in the first attempt.
  - **Description**: `URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(path)")` treats repository-controlled text as URL syntax. A tree entry containing a space returns `nil` (install fails with a misleading `badResponse`), a `#` truncates at a fragment, and a `?` silently redirects the request to a different resource than the one validated. `owner`/`repository` come from user text pasted into Settings, so the same applies there. The file-write side is safe (CR-POS-2), so this is a correctness/robustness defect rather than a write-path escape — but the parsed reference is also used as the security-relevant identity of the install (`source: .gitHub(repository:)`), so garbage-in produces a mislabelled record.
  - **Recommendation**: Validate `owner`/`repository` against `^[A-Za-z0-9._-]+$`, build URLs with `URLComponents`/`appendingPathComponent` (which percent-encodes per segment), and reject segments containing `?`, `#`, or control characters.

- [x] **CR-ITEM-1.7 [Skill installs fetch up to 40 files strictly sequentially with no install-level deadline]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/Extensions/GitHubSkillFetcher.swift:84-145`
  - **Resolution (2026-09-16)**: Fixed earlier in this session: downloads run in a bounded `withThrowingTaskGroup` (5 at a time) under a 60 s install deadline that cancels the group.
  - **Description**: `for path in paths { let data = try await rawFile(…) }` runs one request at a time, up to `maximumFileCount = 40`, each with `timeoutIntervalForRequest = 30` / `timeoutIntervalForResource = 120` (`ExtensionHTTP.swift:60-66`). Worst case an install is minutes of dead time against a slow or hostile host, with only `isWorking` (a boolean) to explain it, and no way to cancel from the UI. Per-file and total byte ceilings exist (good), but no wall-clock budget does.
  - **Recommendation**: Use a bounded `withThrowingTaskGroup` (4–6 concurrent downloads), add an overall install deadline (e.g. 60 s) that cancels the group, and report progress as "N of M files" so a stalled install is legible.

- [x] **CR-ITEM-1.8 [A failed cleanup before install leaves a previous version's files mixed into the new skill]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/Extensions/SkillInstaller.swift:72-90`
  - **Resolution (2026-09-16)**: Fixed. The install writes into a `.staging-<name>-<uuid>` sibling and then `replaceItemAt`s it into place, so the skill directory always holds exactly one version; a failure removes the staging directory and leaves the working version untouched. `SkillInstallerTests.testAReinstallReplacesThePreviousVersionAndAFailedOneLeavesItAlone` asserts all three properties (no stale files, previous version intact after a mid-write failure, no staging leftovers).
  - **Description**: `try? fileManager.removeItem(at: destination)` discards the error, then `createDirectory(withIntermediateDirectories: true)` succeeds even though the directory still exists, and the new files are written over the old ones. A skill re-installed after a partial failure therefore contains a union of two versions — including stale `scripts/*` the manifest no longer describes — and the agent will execute those files later. The installed `SKILL.md` says one thing while the directory holds another.
  - **Recommendation**: Make the clear step fatal (`try fileManager.removeItem`), or install into a temporary directory and `replaceItemAt`/rename into place so the skill directory is always exactly one version. Related: the installer's broader posture (downloaded code executed by the agent later) deserves a trust surface in the UI — show the file list with a "runs code" note at install time (see CR-POS-2 for what is already safe).

- [x] **CR-ITEM-1.9 [Archive fitting re-encodes the entire payload for every 10% trim step]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/AgentCore/SessionArchive.swift:340-361` (`fitted`), `SessionArchive.swift:96-170` (`droppingOldestStoredContent`, the 10% step at line 117), called from `SessionArchiveWriter.write` (`SessionArchive.swift:295-330`) on the debounced save path.
  - **Resolution (2026-09-16)**: Fixed earlier in this session: `dropFraction(encodedSize:ceiling:)` sizes the first trim from the measured overshoot (`min(0.5, max(0.1, overshoot + 0.05))`) so the loop converges in two or three passes instead of decile by decile.
  - **Description**: The loop re-encodes the whole archive after every reduction, and each reduction removes only `max(1, messages.count / 10)` messages of one session (or one session at a time). With `maximumArchiveBytes = 64 MiB`, a single oversized conversation costs roughly *log₁.₁₁(N)* full 64 MB encodes — hundreds of megabytes to gigabytes of JSON encoding work while further saves queue behind the same actor. The trigger is rare (only at the ceiling), which is why this is Medium and not High, but when it hits, it hits the path that also holds the user's unsaved transcript.
  - **Recommendation**: Size the first trim from the measured overshoot instead of a fixed 10%, then let the loop converge in two or three passes. Sketch in [Proposed Code Changes](#proposed-code-changes) (P-1.9).

- [x] **CR-ITEM-1.10 [Extension discovery does file I/O, skill parsing and a synchronous registry write on the main actor]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/Extensions/ExtensionStore.swift:118-126` (`discover()` — `catalog = catalogSource.scan()` then `persist()`), `SkillsCatalog.swift:95-116` (per-skill `String(contentsOf:)` + manifest parse), `ExtensionRegistry.swift:322-340` (`ExtensionRegistryStore.save` → `JSONEncoder().encode` + atomic write, synchronous), invoked from `AgenticSidebarApp.swift:213` and every `refresh()`.
  - **Resolution (2026-09-16)**: Fixed. Discovery runs in `SkillsCatalogCache`, an actor that scans in a detached `Task` off the main actor and answers from cache unless the roots' *and* each `SKILL.md`'s modification times changed; `ExtensionStore` also skips the registry write when discovery produced an equal registry. `SkillsCatalogCacheTests` proves the non-read property by making a file unreadable without changing its modification date (a re-read could not succeed) and by showing a newly added skill and an edited manifest are both picked up.
  - **Description**: `discover()` runs synchronously on `@MainActor`. For each skill root it lists directories and reads+parses every `SKILL.md` in full (a 400-file user skill library is a multi-megabyte read/parse), then JSON-encodes and writes the registry. It runs at launch and on every extension-screen appearance, so the cost is paid repeatedly for data that changes at most when the user edits files. This is the one hot path in the codebase that is still proportional to unbounded user data on the main thread.
  - **Recommendation**: Move scanning into a `SkillsCatalog`-owned actor; key the result on each root's directory mtime so an unchanged library is not re-read; skip `persist()` when the discovered registry equals the stored one (`ExtensionRegistry` is already `Equatable`).

- [x] **CR-ITEM-1.11 [The default global shortcut steals ⌘B from every application]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/Services/GlobalShortcutSpec.swift:8-11` (`static let default`), `Stores/SettingsStore.swift:237-241` (falls back to `.commandB`), registered app-wide via `RegisterEventHotKey` in `Services/GlobalHotKeyController.swift:24-100` (the `RegisterEventHotKey` call is at line 93).
  - **Resolution (2026-09-16)**: Fixed earlier in this session: the default is ⇧⌘B for a fresh install, a stored choice is never rebound (added test), and registration failures are reported in Settings → General instead of only to the log.
  - **Description**: `RegisterEventHotKey` consumes the chord before the frontmost app sees it. ⌘B is "bold" in every text editor and has app-specific meanings across macOS, so a fresh install silently breaks a common system-wide shortcut — and because the app is `LSUIElement`, there is no Dock presence to remind the user why. When registration fails (another app already owns the chord) the failure is only written to `AppLog`; the user is told nothing and the feature simply does not work.
  - **Recommendation**: Default to a rarer chord (⇧⌘B is already a supported choice), store the change as a preference migration so existing installs are not silently rebound, surface registration success/failure and conflicts in Settings → General, and consider leaving the hot key unregistered until the user opts in.

- [x] **CR-ITEM-1.12 [Screenshot auto-analysis silently does nothing on non-English systems]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/Services/ScreenshotMonitorService.swift:244-258` (filename matching against `screenshot`, `ekran resmi`, `screen shot`), gated by `SettingsStore.autoAnalyzeScreenshots`.
  - **Resolution (2026-09-16)**: Fixed. Name matching covers the localized names macOS writes (30 fragments across the languages that ship the OS, matched with `contains` rather than `hasPrefix`) and accepts `.jpeg`/`.heic`/`.tiff`; `kMDItemIsScreenCapture` is consulted as a name-independent fallback when the name does not match. `ScreenshotNamingTests` covers 14 languages plus the false positives (`IMG_4821.png`, `Screenshot-notes.md`).
  - **Description**: macOS names screenshots in the user's language (`Bildschirmfoto`, `Captura de pantalla`, `スクリーンショット`, `Skärmavbild`, …). On any non-English/non-Turkish system the feature reports itself as enabled in Settings and then never fires — the classic "I turned it on and nothing happened" failure the project explicitly designs against elsewhere (e.g. the skill-catalog reject reporting). `.jpg` is accepted while macOS writes `.jpeg` for some export paths, and `Captura de pantalla…` has no matching prefix.
  - **Recommendation**: Detect by localized name mask rather than literal prefixes (e.g. `NSPasteboard`-style defaults lookup for `NSWindow` screenshot prefix, or `NSLocalizedString("Screenshot", …)` plus a per-language list), or verify via metadata (`kMDItemIsScreenCapture` / `kMDItemUserTags`) where available; and accept `.jpeg`/`.heic`.

- [x] **CR-ITEM-1.13 [Cancellation during backend startup is converted into `.startupFailure` and retried]**
  - **Severity**: Medium
  - **Location**: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeServerManager.swift:136-215` — the health-check `catch` chain at lines 188-212 ends in a generic `catch { … lastError = .startupFailure }`.
  - **Resolution (2026-09-16)**: Fixed earlier in this session: `catch is CancellationError` terminates the child and rethrows `CancellationError` instead of recording a startup failure and launching a second child, and `OpenCodeSettings.start` maps a cancelled start to `nil` rather than "OpenCode could not start".
  - **Description**: `URLSessionOpenCodeHealthChecker.waitUntilHealthy` correctly rethrows `CancellationError` (`OpenCodeServerManager.swift:391-425`), but the caller's generic `catch` swallows it: it terminates the child, records `startupFailure`, and loops to launch a **second** child for a task whose owner has already cancelled. The final `throw lastError` then reports a startup problem for what was an ordinary cancellation (e.g. the user pressing stop in Settings, or the `.task` in `AgenticSidebarApp` being torn down). Two children are spawned and one is discarded per cancelled start.
  - **Recommendation**: Insert `} catch is CancellationError { await launchedHandle.terminate(); …; throw CancellationError() }` before the generic `catch`, and map `CancellationError` at the `OpenCodeSettings.start()` call site to "start cancelled" rather than a failure message.

### Low

- [x] **CR-ITEM-1.14 [Composer suggestion selection cuts a range captured from an earlier draft snapshot]**
  - **Severity**: Low
  - **Location**: `Sources/AgenticSidebar/Views/ComposerView.swift:925` (`draft.removeSubrange(trigger.tokenRange)`), with the range created in `Extensions/ExtensionTrigger.swift:25-90` (line 73).
  - **Resolution (2026-09-16)**: Fixed earlier in this session: the token range is validated against the current draft before `removeSubrange`.
  - **Description**: `ExtensionTrigger` carries `Range<String.Index>` values bound to the snapshot of `draft` the body was evaluated against. If the draft has changed since that render — a programmatic edit, an input-method commit, paste, or a queued state update landing between render and tap — `removeSubrange` is called with indices that no longer describe the current string. Swift validates string indices at runtime and traps on an out-of-bounds range, so this is a (narrow) crash path rather than a wrong-result path. The surrounding work to make trigger detection bounded and cheap is otherwise a highlight (CR-POS-4).
  - **Recommendation**: Re-derive the trigger from the current draft and validate it before mutating; if it no longer matches, keep the typed text and just attach the tag. Add a unit test that selects a suggestion after mutating the draft.

- [x] **CR-ITEM-1.15 [Application termination waits forever for the managed backend]**
  - **Severity**: Low
  - **Location**: `Sources/AgenticSidebar/App/AppDelegate.swift:47-64`, `AgenticSidebarApp.swift:178-186` (`managedShutdown`), `OpenCodeProcessLauncher.swift:133-152` (terminate → 20 × 50 ms → SIGKILL).
  - **Resolution (2026-09-16)**: Fixed earlier in this session: `applicationShouldTerminate` races the shutdown against a deadline and replies unconditionally, logging the step that did not finish.
  - **Description**: `applicationShouldTerminate` returns `.terminateLater` and replies only after `managedShutdown()` completes. Every awaited step is bounded individually, but a hung keychain read, a wedged archive write, or a stuck XPC call in `SecItemUpdate` leaves the app with no window that responds, no progress indication, and no way to quit — Command-Q appears to do nothing.
  - **Recommendation**: Race `managedShutdown()` against a short deadline (2–3 s) with `Task` + `Task.sleep`, then reply `true` unconditionally, logging which step did not finish.

- [x] **CR-ITEM-1.16 [The app never verifies that the archive it writes can be read back]**
  - **Severity**: Low
  - **Location**: `Sources/AgenticSidebar/AgentCore/SessionArchive.swift:295-330` (`SessionArchiveWriter.write`), `AgentSessionService.swift:364-395` (`flushPendingSave` / `saveNow`).
  - **Resolution (2026-09-16)**: Fixed earlier in this session: the freshly encoded archive is decoded back before the atomic replace, so a `Codable` regression keeps the previous file instead of replacing it with something unreadable next launch.
  - **Description**: Writes are atomic and byte-bounded, and a damaged file is moved aside on load — good. But nothing round-trips the encoded payload before replacing the previous file, so a `Codable` regression that produces *valid JSON that cannot be decoded by this app* (for example a new non-optional property added to `ChatMessage` or `AgentTurnActivityGroup`) is only discovered on the next launch, when the previous archive has already been replaced and moved aside as corrupt. Shutdown does flush, which limits the loss window, but the failure is silent at the moment it is created.
  - **Recommendation**: In `SessionArchiveWriter.write`, decode the freshly encoded `Data` before the atomic replace (`try decoder.decode(SessionArchive.self, from: fitted.data)`), and on failure log and keep the previous file. Cheap relative to the encode that just happened, and it converts a lost-transcript bug into a logged one.

- [x] **CR-ITEM-1.17 [CI does not gate on warnings, style, or runner availability, and runs a keychain-dependent test]**
  - **Severity**: Low
  - **Location**: `.github/workflows/ci.yml`, `script/build_and_run.sh:14-18`, `Tests/AgenticSidebarTests/KeychainCredentialStoreTests.swift`
  - **Resolution (2026-09-16)**: Fixed. Both CI steps run with `-Xswiftc -warnings-as-errors` (verified on a clean build of the app *and* the test target, which needed six test-side isolation fixes), superseded pushes are cancelled by a `concurrency` group, the SwiftPM build is cached, and the keychain test skips itself unless `RUN_KEYCHAIN_TESTS=1` (CI leaves it unset, so the hermetic suite is what the green tick means: 387 tests, 1 skipped, 0 failures). `swift-format` runs as advisory output because the repository has no `.swift-format` yet — making it a gate would fail every build until the whole tree is reformatted, which is a separate decision.
  - **Description**: The workflow runs `swift build` + `swift test` on the `macos-26` runner label. There is no `concurrency` group (superseded pushes keep burning runner minutes), no caching, no `-Xswiftc -warnings-as-errors`, and no format/lint step — while the codebase is currently warning-free (verified), which is exactly the state worth locking in. `KeychainCredentialStoreTests` performs real `SecItemAdd`/`SecItemDelete` against the login keychain; on a headless runner an unsigned, ad-hoc-signed test binary may be refused or may block, and the README's "hermetic apart from this one test" claim means CI's green tick depends on it.
  - **Recommendation**: Add `-Xswiftc -warnings-as-errors` to both build and test, add a `concurrency: { group: ${{ github.ref }}, cancel-in-progress: true }` block, add `swift-format lint -r Sources Tests` (the repo already targets Swift 6.2+ so the tool is available), and gate the keychain test behind an opt-in env var (`XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1")`) so the hermetic suite is what CI proves.

- [x] **CR-ITEM-1.18 [Raw provider response bodies are logged as public and rendered into the UI]**
  - **Severity**: Low
  - **Location**: `Sources/AgenticSidebar/ProviderGateway/ProviderResponseDiagnostics.swift:41-44` (`privacy: .public`, line 43), surfaced in `Models/SessionErrorPresentation.swift:30-38`.
  - **Resolution (2026-09-16)**: Fixed earlier in this session: the captured snippet is logged with `privacy: .private`; the full text stays available to the UI, which is where the user asked for it.
  - **Description**: The captured snippet (up to 400 chars of the provider's error body) is written to the unified log with `privacy: .public`, meaning any process with log access or any collected sysdiagnose retains it verbatim. Provider error bodies can echo request fragments — model ids, prompts snippets, account or org identifiers, occasionally URL query parameters. The in-app display of the same text is defensible (the user asked why the request failed); the public log is not, especially given `AppLog`'s own documented rule ("never log request bodies").
  - **Recommendation**: Log with `privacy: .private` (still visible to the developer with a provisioning profile attached) or log only the status code and body length, keeping the full snippet for the UI path only.

- [x] **CR-ITEM-1.19 [The generated OpenCode config can carry remote MCP auth headers in a world-readable file]**
  - **Severity**: Low
  - **Location**: `Sources/AgenticSidebar/Extensions/ManagedOpenCodeConfiguration.swift:150-166` (`write`), populated from `GlobalOpenCodeConfigReader.definition` (`GlobalOpenCodeConfigReader.swift:72-105`, which copies `headers`), directory created in `OpenCodeServerManager.managedWorkingDirectoryURL()` (`OpenCodeServerManager.swift:304-315`).
  - **Resolution (2026-09-16)**: Fixed earlier in this session: the managed directory is created `0700` and the configuration `0600`.
  - **Description**: `managed-config.json` is written with `Data.write(atomic:)`, which adopts the process umask — typically `0644`, i.e. readable by every local account — inside a `0755` directory. A remote MCP server's `headers` map (commonly `Authorization: Bearer …`) and its `environment` values are copied into it by design. On a single-user Mac this is minor; on a shared or managed machine it puts credentials in a readable location for no reason.
  - **Recommendation**: Create the managed directory `0700` and `chmod 0600` the config after write; additionally, consider writing header values through OpenCode's own auth path rather than duplicating them into the app's file.

- [x] **CR-ITEM-1.20 [Inconsistent handling of an unreadable-but-present registry file]**
  - **Severity**: Low
  - **Location**: `Sources/AgenticSidebar/Extensions/ExtensionRegistry.swift:294-315` (`load()`), compare `SessionArchiveStore.load()` (`SessionArchive.swift:187-235`).
  - **Resolution (2026-09-16)**: Fixed earlier in this session: the unreadable-but-present registry is moved aside like every other unreadable case, so a recoverable file is never overwritten.
  - **Description**: When `contents(atPath:)` returns `nil` for an existing file, the registry path logs and returns an empty registry **without** moving the file aside, unlike every other unreadable case in the same function and unlike the archive store's consistent "keep it aside, never silently overwrite" policy. The next `save()` then atomically replaces the only copy of what may be a recoverable registry (MCP servers, plugins, skill enablement).
  - **Recommendation**: Call `moveAside()` on that branch too, matching `SessionArchiveStore` and the sibling decode-failure branch three lines below.

- [x] **CR-ITEM-1.21 [Nothing records what the agent actually ran once prompts are disabled]**
  - **Severity**: Low (follows directly from the accepted allow-all decision in CR-ITEM-1.2)
  - **Location**: write path absent; the nearest existing structures are `AgentTurnActivityGroup` (`AgentCore/AgentActivity.swift:99-131`) and `ProviderActivityDescriptor` (`ProviderGateway/ProviderActivity.swift:35-95`), both of which are **bounded and lossy by design** (`SessionArchiveStore.maximumActivitiesPerSession = 120`, 4,000-char outputs, 10% transcript trimming).
  - **Resolution (2026-09-16)**: Implemented as recommended. `ToolAuditLog` (an actor) appends one JSONL line per decision — timestamp, remote session id, tool, title, detail, patterns, *why* it was decided (level / earlier "Always allow" / you / timeout / cancelled) and the reply — to `~/Library/Application Support/AgenticSidebar/OpenCode/audit.jsonl`, rotated at 20 MB across 5 files, mode `0600`, and it is fed by the approval centre, so it records the decisions that never reached the user as well. Settings → AI & Models → Recent tool decisions lists the last 20 with a `Reveal audit log` button. `ToolAuditLogTests` covers read-back order, the limit, a partial final line, rotation and the recorded reason. It deliberately does not duplicate content into the archive.
  - **Description**: With `bash`/`edit`/`external_directory` allowed, the app asks nothing before acting and keeps only a trimmed, in-memory-then-archived preview of what happened. Old activities are pruned to 120 per conversation and tool output is truncated, so after a long session the honest answer to "which commands ran on this machine yesterday, and against which paths?" is not recoverable. The trimming is correct for the *transcript* (it protects the archive and the context window) but it is the wrong store for an accountability record. A per-turn, human-readable confirm step is off the table by decision; an append-only record is the substitute that keeps the same information available without blocking the agent.
  - **Recommendation**: Append one JSONL line per tool invocation to `~/Library/Application Support/AgenticSidebar/OpenCode/audit.jsonl` — timestamp, session id, tool name, working directory, and the sanitized title/command already computed by `OpenCodeStreamNormalizer.extractToolTitleAndDetail` — written from the same actor that already serializes archive writes, with rotation by size (e.g. 20 MB × 5). Surface a "Recent actions" view in Settings that reads it. Do **not** copy this into the archive: the trimming there is intentional, and duplicating it would undo that work. Keep file paths and command text in the record (that is its purpose) and keep it out of `AppLog` (which is `.public` by design) — the local file is the place for it.

---

## Acknowledged Strengths

These are recorded as verified positives, not padding — each was checked in the source.

- [x] **CR-POS-1 — Credential storage is done right.** `KeychainCredentialStore` uses `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (no synchronizable, no iCloud), update-then-add with explicit status handling, distinct errors, and a `CredentialStore` protocol so tests never need the real keychain. The server password is a 32-byte `SecRandomCopyBytes` value and travels in the environment, never in argv (where `ps` would expose it). No credential is written to `UserDefaults`, a plist, or a log.
- [x] **CR-POS-2 — The skill installer's path handling is correct and tested.** `SkillInstaller.resolvedURL(forRelativePath:in:)` rejects absolute paths, `..`, `.` and empty components before joining, and the install destination is a name that must match a real GitHub tree folder *and* pass `SkillManifestParser.isValidName` (`^[a-z0-9]+(-[a-z0-9]+)*$`). I probed the traversal surface deliberately (`../` in the skill name, `..` in a tree path, an absolute path in an archive entry): none reach the filesystem. Coverage exists at `Tests/AgenticSidebarTests/ExtensionTests.swift:408`.
- [x] **CR-POS-3 — The app writes only to directories it owns.** Every writer I traced (`SessionArchiveStore`, `ExtensionRegistryStore`, `ManagedOpenCodeConfiguration`, `ComputerUseFiles`, `SkillInstaller`, screenshot temp files) targets Application Support, the managed OpenCode folder, or the temporary directory. The user's own `opencode.json`, `~/.claude/skills` and `~/.config/opencode/skills` are read-only for this app, and the "silence servers the user did not enable via `tools.<name>_* = false`" trick is the right way to express an override without merging into someone else's file.
- [x] **CR-POS-4 — The streaming hot paths are bounded and cache-keyed, with tests that prove it.** `BoundedChannel` (256 lines) gives real back-pressure on both the HTTP line stream and the event stream; the composer measures only a 2 KB prefix and answers "has content" without allocating; `ExtensionTrigger` scans a 256-char tail instead of the whole draft; `TranscriptIndexCache` keys on cheap invariants so streaming text does not rebuild the rail or activity index; `MarkdownParseCache` + `MarkdownParseStore` memoize parses per view identity with an LRU bounded in both entries and characters. Tests assert the non-rebuild property (`TranscriptIndexTests`, `PerformanceTests`) rather than merely timing it.
- [x] **CR-POS-5 — Concurrency design is coherent.** Actor-owned state (`SessionArchiveWriter`, `ManagedOpenCodeServerManager`, `OpenCodeProviderRuntime`, `BoundedChannel`), `Sendable` value types throughout, `Mutex` for the one piece of shared mutable wiring (`ExtensionSnapshotBox`), no `@unchecked Sendable` outside the deliberately locked `ProviderResponseDiagnostics`, no detach-and-forget tasks on the streaming path, per-turn task identity checks (`guard activeTurnID == turnID`) so a stale turn cannot write into a newer one, and `Task.checkCancellation()` at every loop head. I found no data race and no lock-ordering hazard.
- [x] **CR-POS-6 — Error taxonomy is genuinely useful, not decorative.** `ProviderRuntimeError` → `AgentSessionError` → user-facing text is a clean three-layer pipeline with a shared HTTP-status policy (`ProviderRuntimeError+HTTPStatus`), and the failure classification distinguishes context overflow, rate limiting, rejected credentials and service unavailability rather than collapsing everything into "something went wrong". `preferredCapabilityError` picking the most actionable cause across providers is a nice touch.
- [x] **CR-POS-7 — Data-loss posture is defensive.** Damaged, oversized, or future-versioned archives and registries are moved aside rather than discarded; the archive is byte-capped at write time (not read time, so no load-time wipe); activity timelines are bounded per conversation with tool output truncated and *marked* as truncated; a restored turn that was running at quit is closed instead of counting up forever; the archive writer coalesces debounced writes and skips re-encoding identical payloads.
- [x] **CR-POS-8 — Privacy claims are honest and testable.** `CapturePrivacyCapabilities` was deliberately reduced to the one measurable truth (external capture exclusion is *not* guaranteed, and says so); clipboard and screenshot automation are opt-in, honour `org.nspasteboard.ConcealedType`/`TransientType` and friends, and track pasteboard changes even while disabled so enabling the feature does not submit whatever happened to be on the clipboard. `ClipboardMonitorServiceTests.testConcealedClipboardContentIsNeverSubmitted` asserts the important case.
- [x] **CR-POS-9 — Code quality across the board.** Zero compiler warnings in a clean Swift 6 build; no `try!`, `as!`, or `fatalError`; no force-indexing without a guard; naming and doc comments explain *why* (race conditions, ordering contracts, why a threshold was chosen) rather than restating the code; protocols are narrow and role-named (`OpenCodeExecutableLocating`, `PasteboardReading`, `ExtensionHTTPTransport`) with fakes in tests; 353 hermetic tests pass in under a second.

---

## Proposed Code Changes

Patch-style diffs, ordered by priority. Each is self-contained.

### P-1.1 — Fail closed when no permission handler is installed

`Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProviderRuntime.swift`

```diff
                         let reply: OpenCodePermissionReply
                         if let permissionHandler {
                             reply = await permissionHandler(request)
                         } else {
-                            reply = .always
+                            // Fail closed. A missing decision surface is not
+                            // consent: `.always` here granted every future request
+                            // for the session with nobody left to ask.
+                            reply = .reject
                         }
```

`Tests/AgenticSidebarTests/OpenCodeProviderRuntimeTests.swift` — rename and invert the expectation:

```diff
-    func testWithoutAHandlerPermissionsAreApprovedLikeBefore() async throws {
+    func testWithoutAHandlerPermissionsAreRejectedInsteadOfGrantedForever() async throws {
@@
-        let delivered = await waitForCall(
-            .replyPermission(requestID: "per_2", reply: "always"),
+        let delivered = await waitForCall(
+            .replyPermission(requestID: "per_2", reply: "reject"),
             on: client
         )
```

### P-1.2 — Stop granting allow-all tool permissions by default

`Sources/AgenticSidebar/OpenCodeProvider/OpenCodeServerManager.swift:335-352`

```diff
         let configContent = """
         {
           "$schema": "https://opencode.ai/config.json",
           "permission": {
             "read": "allow",
-            "bash": "allow",
-            "edit": "allow",
             "glob": "allow",
             "grep": "allow",
             "list": "allow",
-            "external_directory": "allow",
             "todowrite": "allow",
-            "webfetch": "allow",
-            "websearch": "allow"
+            "websearch": "allow",
+            "webfetch": "ask",
+            "bash": "ask",
+            "edit": "ask",
+            "external_directory": "ask"
           }
         }
         """
```

Add a Settings row that shows the resolved policy and the path of the file that carries it, so the grant is visible rather than inferred. If the product decision is to keep `allow`, at minimum print the effective policy on first launch and require an explicit "Enable full local access" toggle.

### P-1.13 — Propagate cancellation during backend startup

`Sources/AgenticSidebar/OpenCodeProvider/OpenCodeServerManager.swift:188-212`

```diff
             } catch let error as ProviderRuntimeError {
                 await launchedHandle.terminate()
                 processHandle = nil
                 connection = nil
                 serverStatus = .stopped
 
                 guard error != .authenticationFailure else {
                     throw error
                 }
 
                 lastError = error
                 AppLog.openCode.error(
                     "OpenCode health check failed on attempt \(attempt, privacy: .public)"
                 )
+            } catch is CancellationError {
+                // The owner is gone: do not launch a second child for a start
+                // nobody is waiting for, and do not report it as a failure.
+                await launchedHandle.terminate()
+                processHandle = nil
+                connection = nil
+                serverStatus = .stopped
+                throw CancellationError()
             } catch {
                 await launchedHandle.terminate()
                 processHandle = nil
                 connection = nil
                 serverStatus = .stopped
                 lastError = .startupFailure
             }
```

### P-1.4 — Pass a minimal environment to the child

`Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProcessLauncher.swift:96-115`

```diff
         let process = Process()
         process.executableURL = request.executableURL
         process.arguments = request.arguments
-        process.environment = ProcessInfo.processInfo.environment.merging(
-            request.environment,
-            uniquingKeysWith: { _, new in new }
-        )
+        // Only what the backend needs. Inheriting the whole environment handed
+        // the child (and every plugin it loads) whatever secrets the user had
+        // exported for their shell, none of which a provider credential needs —
+        // credentials travel through OpenCode's own auth API.
+        process.environment = Self.childEnvironment(overrides: request.environment)
@@
     private static let inheritedKeys = [
         "PATH", "HOME", "USER", "SHELL", "TMPDIR", "TMP",
         "LANG", "LC_ALL", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"
     ]
+
+    private static func childEnvironment(overrides: [String: String]) -> [String: String] {
+        let parent = ProcessInfo.processInfo.environment
+        var environment: [String: String] = [:]
+        for key in inheritedKeys {
+            environment[key] = parent[key]
+        }
+        environment.merge(overrides, uniquingKeysWith: { _, new in new })
+        return environment
+    }
```

### P-1.6 — Encode repository-controlled URL components

`Sources/AgenticSidebar/Extensions/GitHubSkillFetcher.swift:225-235`

```diff
     private func rawFile(
         path: String,
         in reference: GitHubRepositoryReference
     ) async throws -> Data {
-        guard let url = URL(
-            string: "https://raw.githubusercontent.com/\(reference.owner)/\(reference.repository)/HEAD/\(path)"
-        ) else {
+        guard let url = Self.rawFileURL(path: path, in: reference) else {
             throw ExtensionFetchError.badResponse
         }
 
         return try await transport.get(url, headers: ExtensionHTTPHeaders.rawText).data
     }
+
+    /// A tree path is repository-controlled text. Pasting it into a URL string
+    /// made a space fail the install and let `?`/`#` silently change which
+    /// resource was requested; joining encoded segments cannot.
+    static func rawFileURL(
+        path: String,
+        in reference: GitHubRepositoryReference
+    ) -> URL? {
+        guard
+            let owner = encodedPathComponent(reference.owner),
+            let repository = encodedPathComponent(reference.repository)
+        else {
+            return nil
+        }
+
+        guard var url = URL(
+            string: "https://raw.githubusercontent.com/\(owner)/\(repository)/HEAD"
+        ) else {
+            return nil
+        }
+
+        for component in path.split(separator: "/") {
+            url.appendPathComponent(String(component))
+        }
+        return url
+    }
+
+    private static func encodedPathComponent(_ component: String) -> String? {
+        guard !component.isEmpty else {
+            return nil
+        }
+
+        var allowed = CharacterSet.urlPathAllowed
+        allowed.remove(charactersIn: "/?#")
+        return component.addingPercentEncoding(withAllowedCharacters: allowed)
+    }
```

### P-1.9 — Converge the archive trim instead of trimming 10% at a time

`Sources/AgenticSidebar/AgentCore/SessionArchive.swift:96-170` and `:340-361`

```diff
-    func droppingOldestStoredContent() -> SessionArchive? {
+    func droppingOldestStoredContent(fraction: Double = 0.1) -> SessionArchive? {
@@
-        // Tek tek düşürmek 64 MB'lık bir arşivi binlerce kez kodlamak demek;
-        // her turda en eski onda bir atılır.
-        let dropCount = max(1, session.messages.count / 10)
+        // Each pass re-encodes the whole payload, so a fixed 10% cut cost dozens
+        // of full encodes at the ceiling. The caller sizes the cut from how far
+        // over the ceiling the encoded payload actually is.
+        let dropCount = max(1, Int(Double(session.messages.count) * fraction))
         session.messages.removeFirst(min(dropCount, session.messages.count - 1))
```

```diff
     private static func fitted(
         _ archive: SessionArchive,
         maximumBytes: Int
     ) throws -> (archive: SessionArchive, data: Data)? {
         var candidate = archive
         var data = try encoder.encode(candidate)
 
         while data.count > maximumBytes {
-            guard let smaller = candidate.droppingOldestStoredContent() else {
+            guard
+                let smaller = candidate.droppingOldestStoredContent(
+                    fraction: dropFraction(encodedSize: data.count, ceiling: maximumBytes)
+                )
+            else {
                 return nil
             }
             candidate = smaller
             data = try encoder.encode(candidate)
         }
 
         return (candidate, data)
     }
+
+    /// How much of the transcript to cut, from the measured overshoot. A payload
+    /// twice the ceiling drops half of it; the loop finishes the remainder.
+    private static func dropFraction(encodedSize: Int, ceiling: Int) -> Double {
+        let overshoot = (Double(encodedSize) / Double(ceiling)) - 1
+        return min(0.5, max(0.1, overshoot + 0.05))
+    }
```

### P-1.11 — Default the global shortcut to ⇧⌘B

`Sources/AgenticSidebar/Services/GlobalShortcutSpec.swift:8-11`

```diff
-    static let `default` = GlobalShortcutSpec(
-        keyCode: UInt32(kVK_ANSI_B),
-        modifiers: UInt32(cmdKey)
-    )
+    /// ⇧⌘B rather than ⌘B: `RegisterEventHotKey` consumes the chord before the
+    /// frontmost app sees it, and plain ⌘B is “bold” almost everywhere.
+    static let `default` = GlobalShortcutSpec(
+        keyCode: UInt32(kVK_ANSI_B),
+        modifiers: UInt32(cmdKey | shiftKey)
+    )
```

`Sources/AgenticSidebar/Stores/SettingsStore.swift:237-241`

```diff
-        } else {
-            globalShortcutChoice = .commandB
-        }
+        } else {
+            globalShortcutChoice = .commandShiftB
+        }
```

Note: the stored preference wins for existing installs; if rebinding them matters, add a one-time migration key rather than silently changing what ⌘B does.

### P-1.14 — Never cut a range that belongs to an older draft

`Sources/AgenticSidebar/Views/ComposerView.swift:920-935`

```diff
     private func select(_ suggestion: ExtensionSuggestion, in trigger: ExtensionTrigger) {
-        draft.removeSubrange(trigger.tokenRange)
+        // `trigger` was captured by an earlier body evaluation and its range
+        // belongs to that snapshot; `removeSubrange` traps on a range that no
+        // longer fits the current draft. Re-detect and only cut what still
+        // matches — otherwise the tag is added and the typed text is left alone.
+        if let current = ExtensionTrigger.detected(in: draft),
+           current.kinds == trigger.kinds,
+           current.tokenRange.upperBound <= draft.endIndex,
+           current.tokenRange.lowerBound < draft.endIndex {
+            draft.removeSubrange(current.tokenRange)
+        }
+
         while let last = draft.last, last == " " {
             draft.removeLast()
         }
```

### P-1.19 — Keep the generated config private

`Sources/AgenticSidebar/Extensions/ManagedOpenCodeConfiguration.swift:150-166`

```diff
-        try FileManager.default.createDirectory(
+        try FileManager.default.createDirectory(
             at: directoryURL,
-            withIntermediateDirectories: true
+            withIntermediateDirectories: true,
+            attributes: [.posixPermissions: 0o700]
         )
         try contents.write(to: fileURL, atomically: true, encoding: .utf8)
+        // A remote MCP server's auth headers are copied into this file by design;
+        // the default umask left it readable by every local account.
+        try? FileManager.default.setAttributes(
+            [.posixPermissions: 0o600],
+            ofItemAtPath: fileURL.path
+        )
         return fileURL
```

### P-1.20 — Move an unreadable registry aside instead of overwriting it

`Sources/AgenticSidebar/Extensions/ExtensionRegistry.swift:294-315`

```diff
         guard let data = fileManager.contents(atPath: fileURL.path) else {
             AppLog.extensions.error("Extension registry is unreadable; starting empty")
+            // Same policy as every other unusable file here: keep it aside, so
+            // the next save cannot irreversibly replace a recoverable registry.
+            moveAside()
             return ExtensionRegistry()
         }
```

---

## Commands

Local verification (all commands are read-only with respect to the repository; `--scratch-path` keeps build output out of the working tree):

```bash
# Compile
swift build --product AgenticSidebar

# Fresh, warning-free build in an isolated scratch directory
swift build --product AgenticSidebar --scratch-path /tmp/as-verify

# Full hermetic suite (353 tests as of this review)
swift test

# Skip the one test that touches the real login keychain
swift test --skip KeychainCredentialStoreTests

# Focused suites for the areas changed on this branch
swift test --filter 'ComposerSubmissionPolicyTests|NativeComposerTextViewTests'
swift test --filter 'PermissionApprovalCenterTests|OpenCodeProviderRuntimeTests'
swift test --filter 'SessionPersistenceTests|BoundedChannelTests|PerformanceTests'

# Proposed CI gate: fail the build on any new warning
swift build -Xswiftc -warnings-as-errors

# Proposed CI style gate
swift-format lint --recursive Sources Tests
```

CI (`.github/workflows/ci.yml`) — suggested additions:

```yaml
concurrency:
  group: ${{ github.ref }}
  cancel-in-progress: true

steps:
  - name: Build (warnings are errors)
    run: swift build --product AgenticSidebar -Xswiftc -warnings-as-errors
  - name: Lint
    run: swift-format lint --recursive Sources Tests
  - name: Test
    run: swift test
```

---

## Effort & Priority Assessment

| Task | Severity | Implementation Effort | Complexity | Dependencies | Priority Score |
| --- | --- | --- | --- | --- | --- |
| **CR-ITEM-1.1** fail-closed permissions | High | < 1 h (+ test edit) | Simple | None | **1 — do first** |
| **CR-ITEM-1.2** default `ask` policy | Accepted | — (policy kept) | — | Author decision taken; only the Settings visibility row remains (~2 h) | **5 — decision closed, visibility optional** |
| **CR-ITEM-1.3** loopback peer verification | Medium | 4–8 h for `libproc`-based verification; 1–2 days for fd-passing | Complex | `libproc`/`posix_spawn` API work; OpenCode launcher contract | **2** |
| **CR-ITEM-1.4** minimal child environment + stderr log | Medium | 1–2 h | Simple | None | **2** |
| **CR-ITEM-1.5** executable ownership check | Medium | 2–3 h | Simple | None | **3** |
| **CR-ITEM-1.6** URL encoding + owner/repo validation | Medium | 1–2 h | Simple | None | **2** |
| **CR-ITEM-1.7** bounded-concurrency install + deadline | Medium | 3–5 h | Moderate | Cancellation plumbing through `ExtensionStore` | **3** |
| **CR-ITEM-1.8** atomic skill replacement | Medium | 2 h | Simple | None | **3** |
| **CR-ITEM-1.9** convergent archive fitting | Medium | 1 h | Simple | None | **2** |
| **CR-ITEM-1.10** off-main discovery + mtime cache | Medium | 4–6 h | Moderate | Actor boundary for `SkillsCatalog`; `Equatable` registry diff | **3** |
| **CR-ITEM-1.11** shortcut default + failure surfacing | Medium | 1 h (+ migration decision) | Simple | Product call on rebinding existing installs | **2** |
| **CR-ITEM-1.12** localized screenshot detection | Medium | 2–4 h | Moderate | Localization testing | **4** |
| **CR-ITEM-1.13** propagate cancellation | Medium | 1 h | Simple | None | **2** |
| **CR-ITEM-1.14** guard the token range | Low | 30 min + test | Simple | None | **2** |
| **CR-ITEM-1.15** bounded shutdown | Low | 1 h | Simple | None | **3** |
| **CR-ITEM-1.16** verify archive round-trip | Low | 1 h | Simple | None | **3** |
| **CR-ITEM-1.17** CI hardening | Low | 1 h | Simple | Runner label availability (`macos-26`) | **2** |
| **CR-ITEM-1.18** private diagnostics logging | Low | 15 min | Simple | None | **2** |
| **CR-ITEM-1.19** config file permissions | Low | 30 min | Simple | None | **2** |
| **CR-ITEM-1.20** registry move-aside | Low | 15 min | Simple | None | **2** |

**Priority score** = risk × effort band, 1 = fix before the next commit, 4 = backlog. Total estimated effort for everything above: **5–8 developer-days**, of which the two High items are under half a day combined.

**Blocking recommendation** (revised after the author accepted the allow-all policy in CR-ITEM-1.2): **CR-ITEM-1.1** (still open — a fail-open default is a code-path accident even when a permissive policy is intended), **CR-ITEM-1.9**, **CR-ITEM-1.13** and **CR-ITEM-1.14** are small, self-contained and each removes a real failure mode. With arbitrary tool execution accepted as the default, the credential-and-process hardening items move up in practical value rather than down: **CR-ITEM-1.3** (the loopback password is now the only boundary in front of an API that runs tools), **CR-ITEM-1.4** (what the child can read) and **CR-ITEM-1.5** (what binary gets executed with it).

## Quality Assurance Task Checklist

- [x] Every finding has a severity level and a clear remediation path (21 findings, each with location, description, recommendation; CR-ITEM-1.2 is recorded as an accepted decision with its follow-ups).
- [x] Security issues are flagged High and appear first (CR-ITEM-1.1, CR-ITEM-1.2, then Medium security items 1.3–1.6).
- [x] Performance suggestions include measurable justification (CR-ITEM-1.7: 40 × up-to-120 s; CR-ITEM-1.9: ~log₁.₁₁(N) full 64 MB encodes; CR-ITEM-1.10: per-appearance full re-parse of every `SKILL.md`).
- [x] Code examples are syntactically valid Swift and match the existing style (4-space indent, doc comments explaining *why*, Turkish comments where the surrounding file uses them).
- [x] All file paths and line references were taken from the working tree at review time and re-checked with `grep -n` before writing.
- [x] The review covers every module in scope: AgentCore, App, ComputerUse, CredentialStore, Extensions, Models, OpenAIProvider, OpenCodeProvider, ProviderGateway, Services, Stores, Support, Views, `Package.swift`, `script/`, `.github/`, and the test suite.
- [x] Positive aspects are acknowledged with verification detail (CR-POS-1 … CR-POS-9).
- [x] Claims about build/test state are backed by commands actually run in this session (clean build, 353 tests, secret scan, force-unwrap scan).
- [x] ~~**Open question for the author**: is the allow-all permission policy in CR-ITEM-1.2 deliberate?~~ **Answered 2026-09-16: yes, intentional.** Recorded as an accepted decision; only the visibility recommendation survives.
- [ ] **Open question for the author**: does the app intend to support remote/third-party MCP servers that require OAuth (the client exposes `startMCPAuthorization`/`completeMCPAuthorization`)? If so, the local-opencode threat model in CR-ITEM-1.3 should be revisited (a remote server plus loopback exposure widens the blast radius).

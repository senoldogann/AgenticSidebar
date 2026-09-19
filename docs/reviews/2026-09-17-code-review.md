# Code Review — AgenticSidebar (Freebuff Desktop)

> **Tarihsel belge (point-in-time).** Bu inceleme 2026-09-16/17 anını ve
> `feat/chat-ux-streaming-activities-enter` dalını kaydeder; aşağıdaki tablodaki
> sayılar o anki ağacın anlık görüntüsüdür, bugünkü hâli değildir (kaynak dosya
> ve test sayıları bu yana arttı; CI artık `swift-format` için bir kapı).
> İzin, süreç yaşam döngüsü ve kalıcılık kararları için hâlâ başvuru kaynağıdır.
> Güncel durum için `README.md` ve aşağıdaki *Commands* bölümüne bakın.

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
  - **Correction (2026-09-19):** the "mid-turn, next tool call" clause no longer holds. Approval level is snapshotted at turn start (`PermissionApprovalCenter.beginTurn`), so a level change applies from the **next turn**; a running turn's pending requests are answered with the level it started with. UI copy, `SettingsStore` and `OpenCodeServerManager` doc comments were corrected alongside this note.
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

---

# Round 3 — deep review: performance, background services, computer-use proof

Date: 2026-09-16 · Branch: `feat/chat-ux-streaming-activities-enter` · HEAD: `986e277` + working tree
Scope: the whole tree, with emphasis on (a) steady-state performance, (b) the
processes the app starts and stops, and (c) an end-to-end proof of the
computer-use chain rather than a proof of its flags.

## Context

- Language/runtime: Swift 6.2 (`-Xswiftc -warnings-as-errors`), SwiftUI, macOS 26.
- Backend: a managed `opencode serve --hostname 127.0.0.1 --port <n> --pure`
  child, plus one child per enabled MCP server, plus the signed
  `ChatGPTSystemComputerRuntime` helper for computer use.
- Evidence in `docs/verification/2026-09-16-deep-review-performance-and-background-services.md`.

## Findings and resolutions

- [x] **CR-ITEM-3.1 [Performance · High] `codesign` on the main actor.**
  - **Location**: `ComputerUse/ComputerUseReadiness.swift` (`SystemComputerUseSignatureReader`), `ComputerUse/ComputerUseStatus.swift` (`refresh`).
  - **Description**: the readiness refresh is `@MainActor` and called it on every
    appearance of the Computer Use card, on every toggle change and after every
    setup run. Inside, the reader spawned `/usr/bin/codesign --display` and called
    `readDataToEndOfFile()` + `waitUntilExit()`. That is a process launch plus two
    blocking waits on the thread that draws the window.
  - **Resolution**: the protocol requirement is now `async`
    (`signingStatus(bundleURL:) async -> ComputerUseSigningStatus`) and the
    implementation does the spawn inside `Task.detached`. A synchronous
    requirement would have invited the same mistake again; the async signature
    makes the blocking call impossible on the main actor. `inspect` was split into
    the cheap filesystem half and `addingSigning(_:)`, so the expensive half is
    opt-in and composable. Tests: the live reader is exercised in the opt-in test;
    the composition is covered by `testSigningIsOnlyAttachedToAnInstalledHelper`.

- [x] **CR-ITEM-3.2 [Performance · High] A full Desktop enumeration plus a Spotlight query per file, once a second, on the main thread.**
  - **Location**: `Services/ScreenshotMonitorService.swift` (`recentScreenshotFileURLs`, `tick`).
  - **Description**: `tick()` runs from a 1 s `Timer` on the main actor. It called
    `contentsOfDirectory(at: ~/Desktop)` and, for every entry, evaluated
    `hasScreenshotName(fileName) || isScreenCaptureByMetadata(url)`. The `||`
    meant **`MDItemCreateWithURL` ran for every entry whose name did not match —
    including PDFs, folders, `.txt` and archives**, because the extension check
    happened inside `hasScreenshotName` only after the metadata call was already
    scheduled. On a Desktop with thousands of files that is thousands of stat +
    Spotlight calls per second, on the main thread.
  - **Resolution**: one predicate, `isScreenshotCandidate(fileURL:metadataProbe:)`,
    with the extension gate first and `metadataProbe` called only for an image
    whose name says nothing; the scan itself is a `nonisolated static`
    (`scanRecentScreenshots`) run from `Task.detached`, and `tick()` is serialized
    with an `isTicking` guard so a slow OCR cannot stack scans. Tests:
    `testSpotlightIsOnlyAskedAboutImagesWhoseNameSaysNothing` asserts the probe is
    called for exactly one file out of seven, and
    `testSpotlightsAnswerIsUsedWhenTheNameSaysNothing` keeps the fallback honest.

- [x] **CR-ITEM-3.3 [Background services · High] A launch could kill a *live* second instance's server.**
  - **Location**: `OpenCodeProvider/OpenCodeServerLedger.swift` (`reapOrphans`).
  - **Description**: the ledger pass killed any recorded pid that was alive and
    whose command line matched the app's fingerprint. The fingerprint cannot tell
    *whose* server it is: with two copies of the app running (the development
    script's `pkill` and relaunch, or a `swift run` beside the built app), the
    second launch would SIGKILL the first launch's backend and its whole MCP tree.
  - **Resolution**: a lease is only acted on when the process has been orphaned
    (`parent == 1`), which is both the accurate definition of "left behind by an
    earlier launch" and impossible to confuse with a running app's child. The
    decision is now a pure function, `shouldReap(_:facts:)`, and the process facts
    are an injectable parameter (`factsProvider`), because a test cannot arrange a
    real orphan of its own but can check every branch of the rule and still
    exercise the real signal. Tests: `testTheReapDecision` (six branches),
    `testAReapEndsAServerRecordedInALease` (real `SIGKILL`),
    `testAReapLeavesAServerThatStillHasALiveParentAlone` (uses the real
    `systemFacts`, asserts the fixture's parent is the test runner).

- [x] **CR-ITEM-3.4 [Background services · Medium] Two orphaned `opencode serve` processes on this machine that the app must not reap.**
  - **Location**: the host, not the code: pid 10904 (`serve --port 41231`, ppid 1,
    ~201 MB RSS, 11 h 45 m) and pid 18276 (`serve --hostname=127.0.0.1
    --port=60848`, ppid 1, ~291 MB RSS, 11 d 23 h). A 16-day-old `uc_driver`
    (Selenium) is running beside them.
  - **Description**: neither matches the app's launch fingerprint (no `--pure`,
    different flag syntax), so the sweep deliberately leaves them alone — the same
    rule that stops a terminal-started server from being killed. They are ~490 MB
    of resident memory that nothing will ever reclaim.
  - **Recommendation (open, author's call)**: end them once by hand:
    `kill 10904 18276` — or leave them if they are in use. A Settings affordance
    that *lists* unowned servers and kills only on an explicit click would be the
    app-side version of this and is recorded as a follow-up, not a fix.

- [ ] **CR-ITEM-3.5 [Performance · Low] The launch-time seeding scan is still synchronous.**
  - **Location**: `Services/ScreenshotMonitorService.swift` (`start`).
  - **Description**: the one scan that runs on the main thread is the seeding pass
    in `start()`. It exists to stop yesterday's screenshots from being analysed on
    the first tick, and it happens once per launch.
  - **Assessment**: accepted as-is. Fixing it means either racing the first tick
    against the seed (a real behaviour change: files created in between would be
    silently skipped) or an async seeding protocol for a saving of one directory
    walk at launch. Recorded so the trade-off is visible, not silently left.

- [ ] **CR-ITEM-3.6 [Performance · Low] The clipboard monitor reads pasteboard types 2.5×/s even when the feature is off.**
  - **Location**: `Services/ClipboardMonitorService.swift` (`tick`).
  - **Description**: `pasteboard.snapshot()` (change count + types + privacy
    markers) runs every 0.4 s on the main actor; the feature-disabled path needs
    only the change count.
  - **Assessment**: measured cost is microseconds and the change count is
    deliberately tracked while disabled (so enabling the feature cannot submit a
    credential copied long before). Left as-is; splitting the snapshot would trade
    a real guarantee for an unmeasurable gain.

- [ ] **CR-ITEM-3.7 [Performance · Low] Two one-second `TimelineView`s keep rendering while visible.**
  - **Location**: `Views/MenuBarSessionView.swift`, `Views/AgentActivityTimelineView.swift`.
  - **Description**: both re-render once a second to animate elapsed time.
  - **Assessment**: view-scoped (nothing renders when the view is off screen) and
    the app measures 0.0 % CPU idle, so this is backlog rather than a fix.

## What is measurably fine

- The app's own steady state: **0.0 % CPU, ~150–170 MB RSS** across a 12-second
  sample, with both background monitors disabled.
- The managed backend idles at **2.3–2.7 % CPU / ~763 MB RSS** and peaks around
  6 % during startup. Nothing the app does drives it: the unified log shows no
  repeating entries (an SSE reconnect storm would), and the only periodic
  app-side fetch — the agent's task list — is event-driven (on a `todo` activity
  and at turn end), not per delta.
- `OpenCodeProcessTree.snapshot()` (all pids, `proc_pidinfo` + `proc_pidpath`) plus
  one `KERN_PROCARGS2` read costs under 10 ms: the ledger test that spawns a
  process, snapshots the table and reads arguments completes in 0.011 s.

## Computer-use: proof rather than assertion

- [x] **CR-POS-3.1 The chain was exercised end to end.** `script/verify-computer-use.mjs`
  drives the same MCP server the app registers, with the same arguments, and then
  calls the real tools. **8/8 steps passed**: handshake (chatgpt-system 0.1.0),
  `tools/list` (19 `computer_*` and 3 `session_authority_*` of 80 tools),
  `computer_run_js` present so the app's deny rule is load-bearing,
  `computer_health` (`state=running`, all four grants true),
  `session_authority_start` (admin lease), `computer_observe` (frontmost
  application: Freebuff — real accessibility data), `computer_screenshot`
  (1710×1112, 868 KiB of real PNG — screen recording, not just its flag).
- [x] **CR-POS-3.2 The app's managed configuration is what the tests say it is.**
  On disk: `chatgpt-system_*: deny` → `chatgpt-system_computer_*: ask` →
  `chatgpt-system_session_authority_*: ask` → `chatgpt-system_computer_health:
  allow` → `chatgpt-system_computer_run_js: deny`, in that order, with
  `instructions` pointing at `computer-use-instructions.md`.
- [x] **CR-POS-3.3 Shutdown leaves nothing behind.** `SIGTERM` to the running app
  (the signal the development script sends) produced "Managed shutdown completed"
  and, afterwards: 0 matching servers, 0 MCP children, 0 helper hosts and
  **0 leases** in `…/OpenCode/servers` — the ledger was written and consumed
  correctly in production, not only in tests.

## Quality assurance

- [x] Every finding has a severity, a location and either a fix with its test or an
  explicit accepted trade-off.
- [x] Fixes are covered by tests: 460 tests, 2 skipped (opt-in keychain and live
  helper), 0 failures, clean under `-warnings-as-errors`.
- [x] Claims about CPU, memory, process counts and log content are the output of
  commands run in this session; the raw transcript is in the verification note.
- [x] The three fixed findings each had a measurable failure mode: a process launch
  on the main thread, thousands of Spotlight queries per second, and a sweep that
  could kill a peer instance.

# Round 4 — macOS Screen Recording is the app's grant, not the helper's

- [x] **CR-ITEM-4.1 [Correctness / Critical] The permissions card read one grant
  from the wrong process.**
  - **Location**: `Sources/AgenticSidebar/ComputerUse/ComputerUseReadiness.swift`,
    `ComputerUseStatus.swift`, `Views/Settings/SettingsComputerUseTab.swift:302-378`
  - **Description**: All four grants were read from the signed helper's `health`
    reply. That is right for three of them and wrong for Screen Recording:
    `tccd` answers `kTCCServiceScreenCapture` for the **responsible** process —
    whoever launched the helper — and never consults the helper's own row. The
    card therefore reported "Screen Recording: Missing" beside a System Settings
    list showing the helper switched on, and granting it again could not change
    anything. Confirmed in the tccd log: the same helper binary returns
    `Auth Right: Unknown (None)` under `Resp:{com.dogan.AgenticSidebar}` and
    `Auth Right: Allowed (System Set)` under `Resp:{com.freebuff.desktop}`.
  - **Recommendation (applied)**: `ComputerUsePermission.subject` names the owner;
    a new `ComputerUseAppPermissionReading` reads this app's own preflights
    in-process and exposes `CGRequestScreenCaptureAccess()` off the main actor, so
    the app lists itself in the pane. `ComputerUseReadiness.isGranted(_:)` and
    `missingPermissions` derive from both sources; the card says which process
    owes what. Tests: 6 new/updated cases plus an injected fake reader everywhere,
    because calling the real preflights would make the suite's result depend on the
    test runner's own grants.

- [x] **CR-ITEM-4.2 [Verification integrity / High] The previous "100 % verified"
  claim measured the wrong tree.**
  - **Location**: `script/verify-computer-use.mjs:298-320`,
    `Tests/AgenticSidebarTests/ComputerUseReadinessTests.swift` (live test)
  - **Description**: Both verification paths spawn the helper from a shell and
    report `screenRecording=true`, which is the **caller's** grant. A green run in
    the terminal could coexist with a correct "Missing" in the app — so the
    earlier claim was true about the other three grants and false about this one.
  - **Recommendation (applied)**: both now state the attribution caveat in the code
    where they read the flag; the screenshot step demands a real frame
    (`> 10 000 bytes`, non-zero dimensions) instead of "bytes came back", because a
    refused capture still answers with a frame that compresses to nothing.

- [x] **CR-POS-4.1 The rules are pinned by tests, not by observation.**
  `missingPermissions == []` while the helper could not be asked (unknown is not
  denied), full-order missing set when the helper answers all four false, and the
  exact production reading — helper `true` for everything, app grant absent —
  asserted as `.missingPermissions([.screenRecording])`.

- [x] **CR-POS-4.2 The chain really does capture when the grant is there.**
  `node script/verify-computer-use.mjs` from a granted shell: 8/8 and a genuine
  1710×1112, 541 KiB PNG. That is the mechanism the app needs; what was missing
  was the grant landing on the right process.

## Quality assurance

- [x] `swift build` / `swift test` clean under `-warnings-as-errors`: **465 tests,
  2 skipped (opt-in), 0 failures**.
- [x] Every claim above is a command output from this session; the transcript is in
  `docs/verification/2026-09-16-screen-recording-attribution-fix.md`.
- [ ] **Open — needs the user**: the app cannot grant itself Screen Recording.
  Pressing **Grant Screen Recording…** lists AgenticSidebar in the pane; toggling
  it on is the remaining step, and the card's Ready line is the confirmation.

---

# Round 5 — delegated subagents and the approval level (2026-09-17)

Scope: the report that subagents are not covered by the app's permissions, and
that they start but stay stuck in the UI. Evidence:
`docs/verification/2026-09-17-subagent-permissions.md`.

## Fixed

- [x] **CR-ITEM-5.1 (Critical) A subagent's permission request was dropped, and
  the subagent hung forever.** `OpenCodeStreamNormalizer` delivered
  `permission.asked` only for the session the subscription was opened for; a
  child session's request carries the child's id. Production: the child's
  `external_directory` asks at 08:48:06/07 have no audit record of any kind, and
  the subagent blocked for 104 s until it was aborted with the parent.
  **Fix (applied)**: permission events are exempt from the session filter, and the
  two-arrivals-of-one-request case shares a single decision. Verified end to end
  by `script/verify-subagent-permissions.mjs` against a real server and a real
  `task` delegation (4/4).
- [x] **CR-ITEM-5.2 (High) A delegated request read as the turn's own.** The
  approval card said "Current conversation" for a question asked by a child
  session. **Fix (applied)**: `OpenCodePermissionRequest.isDelegatedSession`,
  set by the normalizer against the session the turn owns; the card labels it
  *Delegated subagent*.
- [x] **CR-ITEM-5.3 (Medium) Stopping a turn left a subagent's prompt on screen.**
  `rejectAll` matched the parent's remote session id only, so a child's pending
  request survived cancellation — waiter unreleased — until the 180 s timeout.
  **Fix (applied)**: cancellation now carries the conversation as well, and a
  request attributed to that conversation is cleared too.
- [x] **CR-ITEM-5.4 (Medium) The app's `skill: "allow"` was silently discarded.**
  The managed configuration wrote the `skill` key twice (routed rule, then the
  denials). JSON keeps the last one, so every skill fell through to the
  catch-all: `evaluated permission=skill … action.permission=* action.action=ask`.
  **Fix (applied)**: one `skill` member, `{"*": "allow", "<off>": "deny", …}`, with
  the denials last because the same last-rule-wins reading applies inside it.

## Open

- [ ] **CR-ITEM-5.5 (High) The approval level is not the last word, and the app
  does not say so.** Measured on OpenCode 1.18.31: with the machine's own
  `~/.opencode/opencode.json` present, an explicit `bash: ask` (string *and*
  object form, with and without `--pure`, at the top level *and* inside the
  agent) resolves to `allow` — OpenCode turns each agent's enabled `tools` map
  into agent-level rules applied after the configuration. The production audit
  has no `bash` decision at all across 832 `external_directory` ones. The level
  does govern what reaches the app (external paths, `todowrite`, `skill`,
  `task`, web access, the doom-loop guard, MCP and computer-use tools).
  **Recommendation**: read `GET /config` once when the backend starts and, when a
  resolved agent permission contradicts the selected level, say so in Settings →
  AI & Models and on the level control — naming the file that decided it. Today
  the only honest statement lives in the README.
- [ ] **CR-ITEM-5.6 (Medium) A request that never arrives is invisible.**
  `GET /permission` lists everything pending across sessions, and nothing polls
  it. The exemption fixes the cause we found; a reconciliation pass during a turn
  would make the class of failure self-healing rather than merely absent.
- [ ] **CR-ITEM-5.7 (Low) The subagent card cannot show that it is waiting on a
  decision.** The child's own transcript events are still filtered, so the card
  shows "Subagent working (N steps)" with no hint that a prompt is the reason
  nothing moves. The dashboard's pending count covers it only for the active
  conversation.

## Quality assurance

- [x] `swift build` / `swift test` `-warnings-as-errors`: **552 tests, 2 skipped,
  0 failures**.
- [x] Every claim in the verification document is a command output from this
  session; no claim about rule precedence is made without the experiment that
  measured it.
- [x] `script/verify-subagent-permissions.mjs` is permanent, model-free where it
  can be (`--skip-model`) and bounded so it cannot hang a CI run.

---

# Round 6 — the pasted P2/P3 list, verified item by item (2026-09-17)

Scope: the review report handed over as text (three P2 findings, eight P3
bullets). Every item was checked against the working tree before anything was
changed: several had already been fixed in the revision on disk, the rest are
fixed in this round. Evidence:
`docs/verification/2026-09-17-review-followups-p2-p3.md`.

## Already fixed on disk (verified, no change)

- [x] **CR-ITEM-6.1 (P2) Thumbnail cache ignored `maxPixelSize`.** The key is
  `"<path>#<Int(maxPixelSize)>"` (`AttachmentPreviewCache.cacheKey`), so the
  chip's 96 px image can no longer be handed to the transcript (520 px) or the
  inspector (1800 px). Verified at all three call sites, PDF path included
  (shared `imageCache`, same key builder).
- [x] **CR-ITEM-6.2 (P2) The large-file guard in `FileInspectorPanelView`
  really was inverted — the text half is fixed.** `readTextPrefix` reads at most
  1 MB through `FileHandle` and truncates at 100 000 characters; the
  `String(contentsOf:)` branch that read a whole file first is gone.
- [x] **CR-ITEM-6.3 (P2) The "Stealth Mode" wording no longer promises a
  guarantee.** `CapturePrivacyCapabilities.current` reports
  `externalCaptureExclusionApplied` (not `…Guaranteed`) and names the mechanism:
  `NSWindow.sharingType = .none`, "capture paths that do not honor the window
  sharing setting are not covered". Settings → General renders that string.
- [x] **CR-ITEM-6.4 (P3) A corrupt `drafts.json` is no longer overwritten.**
  `ComposerDraftStore.moveAside()` writes `drafts.corrupt.json` before the next
  save, the same policy the archive and the server ledger follow.
- [x] **CR-ITEM-6.5 (P3) The README ↔ code contradiction is gone.** README
  ("rendered lazily … not given an implicit animation") and
  `ConversationDetailView` agree: `LazyVStack`.
- [x] **CR-ITEM-6.6 (P3) The dead preview path is gone.** `onImageTap`,
  `previewImagePath` and `ImagePreviewModal` no longer exist anywhere in
  `Sources`; clicking an image opens the inspector.
- [x] **CR-ITEM-6.7 (P3) `saveImmediately` at the end of every turn is
  accepted and documented** at the call site: structure changes pay one archive
  write, encoding and disk I/O happen in the archive actor.
- [x] **CR-ITEM-6.8 (P3) `approveSafe`'s exact-match list is intentional** —
  `swift build --product …` asks now. `ToolApprovalPolicyTests` pins it.
- [x] **CR-ITEM-6.9 (P3) Pasted-text spills are bounded.**
  `PastedTextAttachment.maximumStoredFiles = 50`, pruned on every write.

## Fixed in this round

- [x] **CR-ITEM-6.10 (P2, remainder) Stealth Mode missed every window born
  after the setting was applied — and the rule existed four times.**
  `sharingType` is not inherited, and each implementation only walked the
  `childWindows` that existed *at that moment*: `CapturePrivacyController`,
  `MainWindowController`, `WindowSharingObservationView` and
  `SettingsWindowController` — the per-site `WindowSharingConfigurator` in the
  MCP sheet existed precisely to work around this. **Fix (applied)**:
  `CapturePrivacyController` is now the single owner; it records the tracked
  window and observes `didBecomeKey` / `didBecomeMain` /
  `didChangeOcclusionState`, applying the current preference the moment a window
  appears (recursively to its children), in both directions. `queue: nil` keeps
  it synchronous with the AppKit post, so the window is set in the same turn it
  appears. Adoption also waits until the preference has been read at least once
  (`hasReadPreference`), so the launch-time default cannot overwrite the stored
  setting before the window registers. Tests:
  `testWindowAppearingLaterIsAdoptedIntoStealthMode`,
  `testWindowAppearingLaterFollowsTheDisabledSetting`,
  `testNoWindowIsTouchedBeforeThePreferenceIsRead`.
- [x] **CR-ITEM-6.11 (P3) A nested hover region clobbered its neighbour's
  pointing hand.** Leaving an inner region set `NSCursor.arrow` while its
  neighbour was still hovered, and `onHover` fires only on change, so the
  neighbour never re-asserted its cursor. **Fix (applied)**: `HoverCursorDepth`,
  a depth counter shared by all five hover modifier variants — the arrow is
  restored only when the last nested region is left. Tests:
  `HoverCursorDepthTests` (3).
- [x] **CR-ITEM-6.12 (P2, remainder) The inspector read its text on the main
  thread on every body pass, and its full-resolution image fallback had no size
  bound.** `loadTextContent()` ran inside `body`, so every re-render (hover,
  theme, resize) re-read and re-decoded 1 MB and re-split it into lines.
  **Fix (applied)**: the prefix is read once per file (`nonisolated
  static readTextPrefix`) on `Task.detached` behind `.task(id: url)`, rendered
  from a `TextPreviewState`; `NSImage(contentsOf:)` is now a last resort gated at
  24 MB. Tests: `FileInspectorTextPreviewTests` (4: bounded read of a ~3 MB
  file, whole small file, binary, missing).
- [x] **CR-ITEM-6.13 (P3) Restored history could forge the block markers.** A
  transcript line containing `[End of restored history.]` produced a second
  marker, and text after it reads like a fresh turn. **Fix (applied)**: the
  markers are constants and restored lines are sanitized (`[…]`), so the block
  has exactly one opening and one closing marker. Content is preserved, only the
  delimiter is neutralised. Test:
  `testRestoredContentCannotForgeTheBlockMarkers`.

## Measured on this machine

- [x] `swift build` / `swift test` `-warnings-as-errors`: **563 tests, 2 skipped
  (opt-in), 0 failures**.
- [x] New probe `script/verify-stealth-windows.swift` reads what the window
  server thinks, not what the app believes: `kCGWindowSharingState` via
  `CGWindowListCopyWindowInfo`. With the machine's own preference
  (`settings.stealthModeEnabled = 0`) it reports `sharing=1 (read-only)` and
  passes with `--expected 1`.
- [x] Rebuilt, signed and reinstalled to `/Applications`; one app process, one
  managed server, one lease (`servers/63471.json`). The two servers with
  `PPID 1` and different signatures are the user's own and were not touched.

## Open

- [ ] **CR-ITEM-6.14 (Low) The probe cannot yet prove the excluded case without
  the user's setting.** With Stealth Mode on it should print
  `sharing=0 (excluded)`; exercising that needs the toggle flipped, so the ON
  path rests on the two adoption tests plus the mechanism itself. A second
  instance launched with `-settings.stealthModeEnabled YES` would prove it at the
  cost of a second backend server for a few seconds.

---

# Round 7 — the crash and the scroll trouble share one cause (2026-09-17)

Scope: "the app crashed suddenly, and scrolling has problems — up and down, or
while a session is running." Evidence:
`docs/verification/2026-09-17-scroll-layout-loop-crash.md`.

## Fixed

- [x] **CR-ITEM-7.1 (Critical) A layout loop aborted the app: 368
  update-constraint passes in one display cycle (limit 367).**
  Two reports, same signature: SIGABRT on the main thread, exception thrown from
  `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]` (reported as
  `lastExceptionBacktrace`), with AppKit's own accounting naming the loop
  (`Marking window … (limit: 367, count: 369)`). **Fix (applied)**: the two
  geometry callbacks in `ConversationDetailView` no longer write view state;
  they record into `ScrollFollowState`, and `body.task` publishes what changed
  every 90 ms — re-writing an unchanged value is itself a drawing pass that
  produces the next measurement. The app's only two `onGeometryChange` /
  `onScrollGeometryChange` call sites were both here (checked by grep), so no
  such callback writes state anywhere now.
- [x] **CR-ITEM-7.2 (High) Scrolling up during an answer did not stick.**
  Follow mode was only ever turned off from inside the scroll callback, and the
  new publish delay would have reopened the same hole; worse, the first version
  of the fix discarded the measurement that arrived mid-gesture. **Fix
  (applied)**: the decision lives with the measurement
  (`ScrollFollowState.shouldAutoFollow`: no gesture, newest measurement at the
  bottom, 0.12 s throttle), and a gesture's final position is honoured rather
  than dropped.
- [x] **CR-ITEM-7.3 (Medium) `<OnScrollGeometryChange> tried to update multiple
  times per frame`.** Momentum scrolling changes the offset several times per
  frame; every change was a full snapshot. **Fix (applied)**: offset and content
  height are rounded to 4 pt before becoming the watched value — the decision
  compares against a 120 pt threshold, so this removes noise, not information.
  (The rail's probe already rounded to 8 pt.)
- [x] **CR-ITEM-7.4 (Medium) A spinning indicator whose layout size could not
  fit its frame.** `ConversationSidebarView` drew the busy marker as a `.small`
  `ProgressView` (16.67 pt of *layout*) with `.scaleEffect(0.6)` (drawing only,
  no layout effect) inside `.frame(width: 12, height: 12)` — min > max, logged as
  `<AppKitProgressView …> has an maximum length (16.666667) that doesn't satisfy
  min (16.666667) <= max (16.666667)`, and only while a session was running.
  **Fix (applied)**: the sidebar marker and the five activity-timeline spinners
  state a floor (`minWidth`/`minHeight`) instead of an exact size.
- [x] **CR-ITEM-7.5 (Low) A throttle value the body never read was `@State`.**
  `lastAutoScrollTime` was written on every streaming flush, invalidating the
  view for a value no view reads. It now lives in `ScrollFollowState`.

## Quality assurance

- [x] `swift build` / `swift test` `-warnings-as-errors`: **577 tests, 2 skipped
  (opt-in), 0 failures**.
- [x] `ScrollFollowStateTests` (13 cases) covers the record/publish split, the
  gesture rules and the throttle; `testScrollCallbacksDoNotWriteViewState` walks
  each geometry callback's body by brace balance and fails on a view-state
  assignment, so the crash's mechanism cannot return unnoticed.
- [x] Rebuilt, signed and reinstalled to `/Applications`; app up (pid 84826), no
  new crash report, the sidebar `AppKitProgressView` diagnostic gone.

## Open

- [ ] **CR-ITEM-7.6 (Low) One `<OnScrollGeometryChange>` diagnostic still fires
  once at launch.** It appears while the initial layout settles; the named
  callback no longer writes state, so this is SwiftUI reporting its own settling
  rather than our loop. The streaming case is the decisive check and needs a
  turn to run — the command is in the verification document.

# Round 8 — the descent that still stuttered (2026-09-17)

Same complaint, second time: *"yukarıdayken aşağıya doğru indirirken hâlâ takılmalar
oluyor; sanki yukarıdan kaydırmayı biri tutuyor da bırakmak istemiyor gibi, ama
iniyor."* Two mechanisms, both measured rather than reasoned about.

## The streaming flush was the jank (CR-ITEM-8.1, High — fixed)

- [x] Measured first, changed second. One flush of a growing answer cost, on the main
  thread: attributed-string build 10.5 → 40.8 ms and set + full layout 19.9 → 27.0 ms
  as the answer went 4.1k → 26.8k characters. Flushes are scheduled every 16–40 ms, so
  work per flush exceeded the cadence and grew with the answer: the main thread never
  idled for the length of a turn. A drag is processed in the gaps, which reads as the
  scroll being *held*.
- [x] `SelectableMarkdownTextView.apply(...)`: rebuild only from the first changed
  block (pulled back one block, because the block that lost its "last" status changes
  its paragraph spacing) and replace only that tail in the text storage. The
  unchanged prefix keeps its attributes **and its layout**.
- [x] Measured after: 2.7 → 15.1 ms per flush became 0.6 → 0.8 ms, flat in the answer
  length. Over 30 flushes: **266.0 ms → 22.7 ms**.
- [x] Side effect: a selection in an earlier paragraph now survives the tail growing.
  `setAttributedString` destroyed it on every flush.
- [x] `MarkdownRunIncrementalUpdateTests` (7 cases) pins it, including equivalence
  with the old path against a **real** `NSTextStorage` (the raw builder output differs
  at the paragraph separator in both paths — `NSTextStorage` applies the paragraph
  style there itself).

## Follow mode's ownership signal was wrong (CR-ITEM-8.2, High — fixed)

- [x] Ownership is now granted by a **falling offset** (≥ 8 pt), which is
  device-independent: growing content never lowers `contentOffset.y`, so a fall cannot
  be mistaken for growth, and a device that reports no scroll phase is covered. The
  SwiftUI phase signal stays, as a second input.
- [x] "At the bottom" narrowed from 120 pt to **40 pt**. At 120 pt a reader a few
  lines up was still inside the band and the streaming answer kept dragging them back.
- [x] `ScrollFollowStateTests` pins the new rules (ownership without any phase report,
  ownership surviving a non-bottom descent, returning into the band handing follow
  back, 4 pt jitter not granting ownership).

## What this round did *not* explain (CR-ITEM-8.1 open item, Medium)

- [x] Found: the previous build's process (pid 84826) was alive at **99% CPU** in a
  SwiftUI update loop — `NSHostingView.beginTransaction` 2141, `AG::Subgraph::update`
  1336, `didRequestHoverUpdate()` 423, `-[NSClipView hitTest:]` 540 samples of 2579 —
  with **no drawing frames and our own view bodies in single digits**. It ignored
  SIGTERM, because its shutdown runs on the main queue and never got control.
- [x] Killed (SIGKILL) with its orphaned server (port 50096). One app (86947) and one
  server (50206) remain; the user's own two servers were left alone.
- [ ] **CR-ITEM-8.3 (Medium, open) The trigger of that loop is not proven.** The fresh
  build sits at 0.1% CPU and has not been seen entering it. Hover re-evaluation plus
  hit testing inside a clip view is what the loop *does*; what starts it is a
  separate investigation, and it should be reproduced before anything is changed on
  the strength of it.

## Verified

- [x] `swift build`, `swift test -Xswiftc -warnings-as-errors`: **588 tests, 2 skipped,
  0 failures**.
- [x] Rebuilt, signed, installed to `/Applications`, launched; one instance, one
  server, no new crash report.
- [ ] The feel of the descent is the user's to confirm; the two mechanisms are
  measured, and both are in the streaming path they blamed.

## Open

- [ ] **CR-ITEM-8.4 (Low) `PromptOffsetProbe` re-measures every user row on every
  scroll step** (`.onGeometryChange` reading `proxy.frame(in: .named(space))`). It is
  quantized to 8 pt and writes only a class, so it does not publish state — but it is
  per-row work inside the scroll path, and it is the one remaining thing in the drag
  path worth measuring on a long conversation.

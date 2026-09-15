# M4 Managed OpenCode Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicitly managed, authenticated loopback OpenCode backend that discovers OpenCode provider/model/variant capabilities dynamically, creates sessions, streams normalized events, aborts work correctly, and exposes server/auth controls in Settings.

**Architecture:** Keep `AgentSessionService` and the SwiftUI chat presentation provider-neutral. A managed OpenCode server controller owns only the app-started `opencode serve` child process and its app-owned Basic Auth secret; an OpenCode HTTP client owns the documented REST/SSE contract; `OpenCodeProviderRuntime` adapts those pieces to `ProviderRuntime`. The server starts only from an explicit Settings action, so app launch never silently launches OpenCode.

**Tech Stack:** Swift 6, SwiftUI/Observation, Foundation `Process`/`URLSession`, Security/Keychain, XCTest, OpenCode 1.18.31 host integration.

**Spec:** `docs/superpowers/specs/2026-09-15-agentic-sidebar-design.md`

## Global Constraints

- Work from M3 commit `ace5e18c6789f6a2c6fcf21d5b31b61c645d71b9` on `feat/m4-managed-opencode-adapter`.
- Do not silently download or update OpenCode.
- Managed OpenCode binds only to `127.0.0.1` and always uses HTTP Basic Auth.
- The managed server password is application-owned and stored through `CredentialStore`, never UserDefaults or logs.
- OpenCode provider credentials are forwarded to OpenCode through its auth API and are not persisted by AgenticSidebar.
- Presentation and `AgentSessionService` must not import OpenCode-specific transport types.
- Long-lived process/stream work has explicit ownership and cancellation.
- Do not require a billable/live provider inference for unit or host integration verification.
- No push unless explicitly requested.

---

### Task 1: Provider-neutral backend lifecycle errors

**Files:**
- Modify: `Sources/AgenticSidebar/ProviderGateway/ProviderRuntime.swift`
- Modify: `Sources/AgenticSidebar/AgentCore/AgentSessionState.swift`
- Modify: `Sources/AgenticSidebar/AgentCore/AgentSessionService.swift`
- Modify: `Tests/AgenticSidebarTests/AgentSessionServiceTests.swift`

**Interfaces:**
- Produces `ProviderRuntimeError.executableUnavailable`, `.startupFailure`, `.authenticationFailure`.
- Produces matching provider-neutral `AgentSessionError.backendExecutableUnavailable`, `.backendStartupFailure`, `.authenticationFailure`.

- [ ] Add failing mapping tests for all three errors.
- [ ] Run `swift test --filter AgentSessionServiceTests` and verify RED because cases do not exist.
- [ ] Add the minimal enum cases and `sessionError(for:)` mappings.
- [ ] Run focused tests and verify GREEN.

### Task 2: Managed OpenCode executable and server lifecycle

**Files:**
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeServerManager.swift`
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProcessLauncher.swift`
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeServerConnection.swift`
- Modify: `Sources/AgenticSidebar/CredentialStore/CredentialStore.swift`
- Create: `Tests/AgenticSidebarTests/OpenCodeServerManagerTests.swift`

**Interfaces:**
- `OpenCodeServerConnection { baseURL, username, password }` holds the in-memory connection material required for authenticated loopback requests.
- `OpenCodeServerManaging` exposes `status()`, `start() async throws -> OpenCodeServerConnection`, `currentConnection() async -> OpenCodeServerConnection?`, and `stop() async`.
- `ManagedOpenCodeServerManager` detects an executable from injected candidates/PATH, uses `CredentialKey.openCodeServerPassword`, launches `opencode serve --hostname 127.0.0.1 --port <explicit> --pure`, health-checks `/global/health`, and owns only its launched process.

- [ ] Write tests for missing executable, exact loopback/port arguments, Basic Auth environment, generated/persisted server password reuse, successful health readiness, startup failure cleanup, and explicit stop.
- [ ] Verify focused RED.
- [ ] Implement locator, launcher protocol/production `Process` launcher, random port allocator, app-owned server password resolution, health probe, and lifecycle actor.
- [ ] Verify focused GREEN.

### Task 3: OpenCode HTTP/SSE client and dynamic capability mapping

**Files:**
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeTransport.swift`
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeClient.swift`
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeModels.swift`
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeStreamNormalizer.swift`
- Create: `Tests/AgenticSidebarTests/OpenCodeClientTests.swift`
- Create: `Tests/AgenticSidebarTests/OpenCodeStreamNormalizerTests.swift`

**Interfaces:**
- `OpenCodeTransport` mirrors send/line-stream cancellation without containing provider semantics.
- `OpenCodeClient.providers()` decodes `{ all, connected, default }` and exposes only connected provider models to the runtime.
- Model IDs are flattened as `providerID/modelID`; parsing splits only the first `/`, preserving slashes inside model IDs.
- Model variant names come directly from each model's `variants` map and are sorted for deterministic presentation.
- `OpenCodeClient.authMethods()` decodes API/OAuth method descriptors; `setAPIKey(providerID:key:metadata:)` sends `{ type:"api", key, metadata? }` to `PUT /auth/:id`.
- Session methods: `createSession()`, `sendPromptAsync(...)`, `abort(sessionID:)`, `eventStream()`.
- `OpenCodeStreamNormalizer` buffers unknown `message.part.delta` values until part type is known, emits text only for text parts, maps tool running/completed to tool events, maps target-session idle to completion, and normalizes session errors.

- [ ] Write failing request/response/auth/session tests with mocked transport.
- [ ] Write failing stream-normalizer tests including delta-before-part-updated race, reasoning suppression, tool state, idle completion, unrelated-session filtering, and session error.
- [ ] Verify RED.
- [ ] Implement the minimal client/models/normalizer and Foundation URLSession transport with Basic Auth request construction.
- [ ] Verify focused GREEN.

### Task 4: `OpenCodeProviderRuntime: ProviderRuntime`

**Files:**
- Create: `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeProviderRuntime.swift`
- Create: `Tests/AgenticSidebarTests/OpenCodeProviderRuntimeTests.swift`

**Interfaces:**
- Runtime ID is `ProviderID("opencode")`, display name `OpenCode`.
- `capabilities()` requires an already-running managed connection; it never starts OpenCode implicitly.
- Runtime keeps an actor-isolated mapping from AgenticSidebar session UUID to OpenCode session ID.
- `startStream` opens `/event` before `prompt_async`, sends only the newest user message with selected `{ providerID, modelID }` and optional variant, normalizes target-session events, and exposes cancellation that calls both `/session/:id/abort` and the underlying SSE cancellation.

- [ ] Write failing tests for unavailable server, connected capability mapping, create-session-on-first-turn/reuse-on-next-turn, event-before-prompt ordering, model/variant encoding, normalized streamed text/tool/completion, and abort + SSE cancellation.
- [ ] Verify RED.
- [ ] Implement minimal runtime/session registry.
- [ ] Verify focused GREEN.

### Task 5: OpenCode Settings controls and app wiring

**Files:**
- Create: `Sources/AgenticSidebar/Stores/OpenCodeSettings.swift`
- Modify: `Sources/AgenticSidebar/Views/SettingsView.swift`
- Modify: `Sources/AgenticSidebar/App/AgenticSidebarApp.swift`
- Create: `Tests/AgenticSidebarTests/OpenCodeSettingsTests.swift`

**Interfaces:**
- Settings state exposes installed/running/version status, explicit Start/Stop actions, API-capable auth methods, selected provider/method, `apiKeyDraft`, prompt metadata drafts, and user-safe errors.
- API keys exist only in the SecureField draft until `setAPIKey` succeeds, then the draft is cleared.
- Starting/stopping or changing OpenCode auth triggers `AgentSessionService.refreshCapabilities()`.
- `AgentSessionService` is constructed with both OpenAI and OpenCode runtimes sharing the same managed OpenCode server manager.

- [ ] Write failing state tests for start/stop, API auth save/clear, no secret persistence, metadata forwarding, and safe errors.
- [ ] Verify RED.
- [ ] Implement observable settings state and SwiftUI section with Start/Stop, dynamic API provider/method picker, SecureField, and metadata fields for text/select prompts.
- [ ] Wire runtime into the app without auto-starting the server.
- [ ] Verify focused GREEN.

### Task 6: Full automated verification

**Files:** all M4 changes.

- [ ] Run `swift test`; all tests must pass.
- [ ] Run `swift build --product AgenticSidebar`; exit 0 required.
- [ ] Inspect unstaged diff for secret literals, UserDefaults credential persistence, non-loopback hostnames, accidental binary download/update logic, or provider-specific presentation coupling.
- [ ] Run `project_check` on the exact dirty tree before host smoke.

### Task 7: Real-host OpenCode 1.18.31 integration and macOS regression smoke

**Files:** no production changes unless a real defect is found.

- [ ] Verify `/opt/homebrew/bin/opencode` version `1.18.31` is still present.
- [ ] Launch the app and use Settings Start OpenCode; verify managed server health reports 1.18.31 and is reachable only at `127.0.0.1` with auth.
- [ ] Verify unauthenticated health request is rejected and authenticated `/provider` discovery succeeds.
- [ ] Verify OpenCode appears in the backend picker after refresh and discovered model/variant choices are non-empty when connected models exist.
- [ ] Create/delete a server session and verify event connection without making a live billable model request.
- [ ] Stop OpenCode from Settings and verify the owned process exits and backend becomes unavailable after refresh.
- [ ] Re-run Dock absence, Command-B hide/show, Command-W process survival/reopen, MenuBarExtra, Settings, and OpenAI SecureField checks.

### Task 8: Final local commit and continuity

- [ ] Re-run fresh `swift test`, `swift build --product AgenticSidebar`, and `./script/build_and_run.sh --verify` after any host fixes.
- [ ] Stage only intended M4 paths and inspect staged diff.
- [ ] Commit locally with `feat: add managed OpenCode adapter` only if every automated and host check passes.
- [ ] Verify clean status/log; do not push.
- [ ] Complete M4 task state and update `AgenticSidebar` project continuity with exact HEAD, installed OpenCode version, verification evidence, and remaining M5 acceptance work.

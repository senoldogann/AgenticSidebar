# M5 Integrated Acceptance Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the first AgenticSidebar milestone with deterministic integrated tests, real-host verification of both backend paths and native background behavior, and an explicit capture-privacy test matrix without adding unsupported guarantees.

**Architecture:** M5 is an acceptance milestone, not a new subsystem. Existing provider-neutral core, OpenAI adapter, OpenCode adapter, app shell, Keychain boundary, and capture-privacy controller remain the implementation under test; production code changes are allowed only for defects reproduced during acceptance and must follow RED → GREEN TDD. Evidence is split into automated, backend-integration, and real-host macOS results.

**Tech Stack:** Swift 6, XCTest, SwiftUI/AppKit, macOS Keychain, Foundation networking, installed OpenCode 1.18.31, host accessibility/process/network diagnostics.

**Spec:** `docs/superpowers/specs/2026-09-15-agentic-sidebar-design.md`

## Global Constraints

- Baseline is clean M4 commit `7b6007d53af3f69a05808feeabe655f2366eb6e0` on `feat/m5-integrated-acceptance`.
- Do not silently download/update OpenCode or add a new direct provider.
- Do not spend provider quota or perform a billable live inference solely for acceptance; direct OpenAI live checks are capability/discovery-only unless an already-approved no-cost path exists.
- User/provider secrets must never be printed, copied into fixtures, UserDefaults, normal logs, or acceptance documents.
- Managed OpenCode remains loopback-only and authenticated.
- Capture privacy remains explicitly best-effort; acceptance must record actual host behavior rather than claim guaranteed exclusion.
- Production code changes require a reproduced failure and a failing regression test first.
- No push.

---

### Task 1: Add deterministic first-milestone integration tests

**Files:**
- Create: `Tests/AgenticSidebarTests/FirstMilestoneIntegrationTests.swift`

**Interfaces:**
- Consumes `AgentSessionService`, `ProviderRuntime`, `ProviderCapabilities`, `ProviderStream`, and provider-neutral configuration types.
- Produces deterministic coverage that OpenAI-like and OpenCode-like runtimes coexist, provider/model/variant switching routes work to the selected runtime, and an owned stream continues independent of window presentation.

- [ ] Write a failing test `testTwoBackendsCoexistAndSubmissionRoutesToSelectedRuntime` using two recording fake runtimes. After `refreshCapabilities()`, assert both capabilities exist; switch to the second runtime/model/variant; submit; assert only that runtime receives the request and assistant output completes.
- [ ] Write a failing test `testOwnedSessionContinuesWithoutPresentationInteraction` using a controllable stream. Submit, wait for `.streaming`, then emit text/completion without touching presentation/window objects; assert the session reaches `.completed` with the streamed assistant message.
- [ ] Run `swift test --filter FirstMilestoneIntegrationTests` and verify RED for the intended integration expectation or test harness gap.
- [ ] If current production behavior already satisfies the requirement and the test is valid, retain the test as acceptance coverage without changing production code. If a real behavior gap is exposed, add only the minimal TDD fix.
- [ ] Re-run focused tests and require GREEN.

### Task 2: Establish credential and backend-discovery acceptance state

**Files:**
- Create: `docs/verification/2026-09-15-first-milestone-acceptance.md`

**Interfaces:**
- Records evidence only; never records credential values or Authorization material.

- [ ] Start the Admin host lane and run fresh `swift test`, `swift build --product AgenticSidebar`, and `./script/build_and_run.sh --verify` before backend host checks.
- [ ] Detect whether the application-owned OpenAI Keychain item exists using metadata-only lookup; do not request or print the secret value.
- [ ] Verify Settings exposes the OpenAI credential as an `AXSecureTextField` and static scans show no OpenAI/OpenCode secret persistence in `UserDefaults` or normal logs.
- [ ] If the OpenAI credential exists, launch the signed app and verify `OpenAI` appears in the provider picker after capability refresh and that its model/effort controls are non-empty and capability-scoped. Do not submit a billable response request.
- [ ] If the OpenAI credential is absent, record the exact M5 acceptance gap as blocked rather than fabricating a live OpenAI result; continue all non-OpenAI acceptance checks.

### Task 3: Verify managed OpenCode end-to-end without billable inference

**Files:**
- Update: `docs/verification/2026-09-15-first-milestone-acceptance.md`

**Interfaces:**
- Uses the installed `/opt/homebrew/bin/opencode` and the app-owned managed child only.

- [ ] Verify installed OpenCode version is still `1.18.31`.
- [ ] From Settings, explicitly Start OpenCode and verify the owned child uses `serve --hostname 127.0.0.1 --port <explicit> --pure`, dedicated AgenticSidebar Application Support CWD, and loopback-only listen socket.
- [ ] Verify unauthenticated `/global/health` is rejected with 401/403 while Settings reports healthy/running `1.18.31` through the authenticated app path.
- [ ] Verify provider picker includes `OpenCode`, dynamic model choices are present, and a model with variants exposes non-empty variant choices.
- [ ] Run a disposable non-billable OpenCode session/SSE probe: create session, observe `server.connected` plus session lifecycle events, delete session, and make no model inference call.
- [ ] Stop OpenCode from Settings; verify the app-owned child exits and OpenCode is removed from available provider controls after capability refresh.

### Task 4: Verify native background/session and menu-bar acceptance

**Files:**
- Update: `docs/verification/2026-09-15-first-milestone-acceptance.md`

**Interfaces:**
- Uses the shared app-level `AgentSessionService` and native window/menu-bar surfaces.

- [ ] Verify no normal Dock icon is present.
- [ ] Verify the optional MenuBarExtra exists when enabled and reflects the same `SessionPresentationState` status semantics covered by tests.
- [ ] Verify Command-B main-window toggle `visible → hidden → visible` on the real host.
- [ ] Verify Command-W closes the window without terminating the process, and Command-B recreates/reopens it.
- [ ] With managed OpenCode running, verify hiding/closing the main window leaves both AgenticSidebar and the managed child alive; then explicitly Stop or Quit and verify owned child cleanup.
- [ ] Verify disabling MenuBarExtra affects presentation only and does not terminate the AgenticSidebar process or an owned managed OpenCode child; restore the original setting before finishing.

### Task 5: Record the host capture-privacy matrix

**Files:**
- Create: `docs/verification/2026-09-15-capture-privacy-matrix.md`
- Update: `docs/verification/2026-09-15-first-milestone-acceptance.md`

**Interfaces:**
- Consumes `CapturePrivacyCapabilities.current` semantics: external exclusion is not guaranteed; self-capture filtering is a capability for app-owned ScreenCaptureKit usage, not arbitrary third-party capture.

- [ ] Verify Settings/UI text does not claim guaranteed screenshot or third-party capture exclusion.
- [ ] Capture the AgenticSidebar main window using supported macOS screenshot tooling and record whether the capture succeeds; do not modify production code to suppress it with private/legacy APIs.
- [ ] Record external/system screenshot behavior as observed on this host, with OS/tool context and result.
- [ ] Record ScreenCaptureKit self-capture filtering as `not exercised / no app-owned capture feature in first milestone` unless a real app-owned capture path exists; do not convert capability support into a guarantee claim.
- [ ] Verify existing `CapturePrivacyControllerTests` continue to assert `externalCaptureExclusionGuaranteed == false` and no legacy window-sharing restriction.

### Task 6: Final integrated acceptance gate

**Files:**
- All M5 test/doc changes plus any test-first defect fixes found above.

- [ ] Run `swift test`; require zero failures and record exact count.
- [ ] Run `swift build --product AgenticSidebar`; require exit 0.
- [ ] Run `./script/build_and_run.sh --verify`; require exit 0 and running signed app process.
- [ ] Run `git diff --check` and scan the complete M5 diff for secret values, `UserDefaults` credential persistence, non-loopback OpenCode bind changes, silent download/update logic, unsupported capture claims, and provider-specific presentation coupling.
- [ ] Run `project_check` on the exact current tree; require test/build PASS.
- [ ] If any mandatory acceptance item is blocked (especially missing live OpenAI credential/discovery), leave M5 active/blocked and do not claim first-milestone completion.
- [ ] If all mandatory acceptance items pass, stage only intended M5 paths, inspect staged diff, commit locally as `test: complete first milestone acceptance`, verify clean status and post-commit `project_check`, update continuity, and do not push.

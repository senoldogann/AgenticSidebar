# AgenticSidebar M2 Provider-Neutral Chat Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a provider-neutral, process-owned chat/session core with capability-driven provider/model/variant selection, normalized streaming, explicit cancellation, and a SwiftUI chat presentation that depends only on the core/provider port.

**Architecture:** Keep the existing single SwiftPM executable target, but introduce source-level `AgentCore` and `ProviderGateway` boundaries that match the approved architecture contract. Concrete OpenAI/OpenCode transports remain out of M2; `AgentSessionService` owns observable session state and long-lived turn tasks, while provider runtimes expose normalized capabilities and `ProviderStream` events. SwiftUI observes only `AgentSessionService`, so later adapters can be injected without changing presentation logic.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, structured concurrency, `AsyncThrowingStream`, XCTest, macOS 26.0 deployment target.

**Spec:** `docs/superpowers/specs/2026-09-15-agentic-sidebar-design.md`

## Global Constraints

- Native macOS application; SwiftUI-first with narrow AppKit interop.
- Minimum deployment target remains macOS 26.0 and Swift language mode remains Swift 6.
- Keep one SwiftPM executable target and one XCTest target for M2; do not add a package dependency.
- `Views` may depend on `AgentCore`; neither `AgentCore` nor `Views` may import future concrete OpenAI/OpenCode transport code.
- Provider/model/variant options come from `ProviderCapabilities`; unsupported combinations must be rejected by core state transitions.
- Long-lived turn work is owned by `AgentSessionService`; cancellation must cancel both the consumer task and the provider stream cancellation hook.
- Raw provider errors, credentials, authorization material, or request bodies must not be copied into user-visible error state.
- No concrete OpenAI/OpenCode networking, Keychain work, OpenCode process management, or automatic provider installation belongs in M2.
- Preserve the verified M1 lifecycle behavior: Command-B, close/reopen activation, Dock-less accessory policy, menu-bar toggle, and best-effort capture policy.
- Every new behavior-bearing production API is introduced with a failing focused XCTest first, followed by focused GREEN and then full regression verification.

---

### Task 1: Provider-port capability and stream contracts

**Files:**
- Create: `Sources/AgenticSidebar/ProviderGateway/ProviderTypes.swift`
- Create: `Sources/AgenticSidebar/ProviderGateway/ProviderRuntime.swift`
- Test: `Tests/AgenticSidebarTests/ProviderCapabilitiesTests.swift`

**Interfaces:**
- Produces: `ProviderID`, `ProviderModelID`, and `ProviderVariantID` as `Hashable & Sendable` string-backed identifiers.
- Produces: `ProviderVariant`, `ProviderModelCapability`, `ProviderCapabilities`, and `SessionConfiguration` as `Equatable & Sendable` value types.
- Produces: `ProviderRequest { sessionID, configuration, messages }`.
- Produces: `enum ProviderEvent { assistantTextDelta(String), toolStarted(String), toolFinished, waiting, completed }`.
- Produces: `struct ProviderStream { events: AsyncThrowingStream<ProviderEvent, Error>; cancel() async }`.
- Produces: `protocol ProviderRuntime: Sendable { var id: ProviderID { get }; func capabilities() async throws -> ProviderCapabilities; func startStream(for request: ProviderRequest) async throws -> ProviderStream }`.

- [ ] **Step 1: Write failing capability tests**

Create `ProviderCapabilitiesTests` that constructs one provider with two models and verifies `model(id:)` returns only an exact model match and `supports(variantID:for:)` returns true only when the variant belongs to that exact model. Include a model with no variants and assert `nil` is a valid optional selection while an arbitrary variant is rejected.

```swift
func testVariantSupportIsScopedToSelectedModel() {
    let fast = ProviderVariant(id: ProviderVariantID("fast"), displayName: "Fast")
    let deep = ProviderVariant(id: ProviderVariantID("deep"), displayName: "Deep")
    let capabilities = ProviderCapabilities(
        id: ProviderID("test"),
        displayName: "Test",
        models: [
            ProviderModelCapability(id: ProviderModelID("alpha"), displayName: "Alpha", variants: [fast]),
            ProviderModelCapability(id: ProviderModelID("beta"), displayName: "Beta", variants: [deep])
        ]
    )

    XCTAssertTrue(capabilities.supports(variantID: fast.id, for: ProviderModelID("alpha")))
    XCTAssertFalse(capabilities.supports(variantID: deep.id, for: ProviderModelID("alpha")))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --filter ProviderCapabilitiesTests`
Expected: compile failure because the provider capability types do not exist.

- [ ] **Step 3: Implement the minimal provider-port value types**

Keep identifiers provider-neutral and do not add `.openAI` / `.openCode` enum cases. `ProviderCapabilities.model(id:)` performs exact lookup. `supports(variantID:for:)` returns `true` for `nil`, otherwise requires the selected model to contain that variant.

- [ ] **Step 4: Add the normalized runtime/stream contract**

`ProviderStream` stores an `AsyncThrowingStream<ProviderEvent, Error>` plus an `@Sendable () async -> Void` cancellation closure. Its public `cancel()` delegates to that closure. The provider runtime protocol returns this type and contains no UI types.

- [ ] **Step 5: Run GREEN**

Run: `swift test --filter ProviderCapabilitiesTests`
Expected: PASS.

---

### Task 2: Provider-neutral session state and capability-driven configuration

**Files:**
- Create: `Sources/AgenticSidebar/AgentCore/ChatMessage.swift`
- Create: `Sources/AgenticSidebar/AgentCore/AgentSessionState.swift`
- Create: `Sources/AgenticSidebar/AgentCore/AgentSessionService.swift`
- Test: `Tests/AgenticSidebarTests/AgentSessionServiceTests.swift`
- Test support: `Tests/AgenticSidebarTests/TestProviderRuntime.swift`

**Interfaces:**
- Produces: `ChatMessage` with `Role.user` / `.assistant`, stable `UUID`, and mutable text content.
- Produces: `AgentSessionStatus` cases `idle`, `streaming`, `runningTool(String)`, `waiting`, `cancelling`, `completed`, `cancelled`, `failed`.
- Produces: `AgentSessionError` normalized cases `providerUnavailable`, `unsupportedCapability`, `transportFailure`, `streamInterrupted`, `unexpectedBackendResponse`.
- Produces: `AgentSessionState { id, configuration, messages, status, error, startedAt, completedAt }`.
- Produces: `@MainActor @Observable final class AgentSessionService` initialized with `[any ProviderRuntime]`.
- Produces: read-only `providers`, `availableModels`, `availableVariants`, `isBusy`, `canSubmit`, and mutable behavior through `refreshCapabilities()`, `selectProvider(_:)`, `selectModel(_:)`, `selectVariant(_:)`, `submit(_:)`, and `cancel()`.

- [ ] **Step 1: Write failing initial-capability and selection tests**

Use two `TestProviderRuntime` instances. Verify `refreshCapabilities()` preserves runtime injection order, selects the first provider/model when no valid configuration exists, and keeps `variantID == nil`. Verify selecting the second provider selects that provider's first model and clears a variant from the previous provider.

```swift
@MainActor
func testSwitchingProviderRebuildsConfigurationFromThatProvidersCapabilities() async {
    let service = AgentSessionService(runtimes: [alphaRuntime, betaRuntime])
    await service.refreshCapabilities()

    try? service.selectVariant(ProviderVariantID("fast"))
    try? service.selectProvider(ProviderID("beta"))

    XCTAssertEqual(service.state.configuration?.providerID, ProviderID("beta"))
    XCTAssertEqual(service.state.configuration?.modelID, ProviderModelID("beta-1"))
    XCTAssertNil(service.state.configuration?.variantID)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --filter AgentSessionServiceTests`
Expected: compile failure because the session core does not exist.

- [ ] **Step 3: Implement minimal state plus capability refresh**

`refreshCapabilities()` asks each injected runtime for capabilities in injection order. Ignore failed runtimes if at least one provider succeeds; if runtimes were supplied but none succeed, set `status = .failed` and `error = .providerUnavailable`. An empty runtime list is a valid pre-adapter M2 state and remains idle with no configuration.

- [ ] **Step 4: Implement strict configuration mutation**

`selectProvider`, `selectModel`, and `selectVariant` are allowed only when no turn is active. They validate against the currently loaded capability set; invalid IDs throw `AgentSessionError.unsupportedCapability` and do not mutate the previous valid configuration. Changing provider picks its first model and clears the variant; changing model clears a variant that the new model does not support.

- [ ] **Step 5: Run GREEN for capability/configuration tests**

Run: `swift test --filter AgentSessionServiceTests`
Expected: all configuration-focused tests PASS before streaming tests are added.

---

### Task 3: Streaming normalization and explicit cancellation

**Files:**
- Modify: `Sources/AgenticSidebar/AgentCore/AgentSessionService.swift`
- Modify: `Tests/AgenticSidebarTests/AgentSessionServiceTests.swift`
- Modify: `Tests/AgenticSidebarTests/TestProviderRuntime.swift`

**Interfaces:**
- `@discardableResult submit(_:) -> Task<Void, Never>?` owns one active turn task, returns that same task as an observation handle for tests/callers that need to await completion, and appends the user message before starting provider work.
- `ProviderEvent.assistantTextDelta` creates/extends exactly one assistant message for the active turn.
- Tool/waiting/completed events normalize into `AgentSessionStatus` without leaking provider event types to SwiftUI.
- `cancel() async` transitions through `.cancelling`, cancels the owned consumer task, awaits `ProviderStream.cancel()`, waits for the owned task to terminate, then ends in `.cancelled` without allowing stale events to mutate state.

- [ ] **Step 1: Add failing streaming tests**

Create a test runtime whose stream yields two text deltas followed by `.completed`. Capture the task returned by `submit("Hello")`, await `task.value`, then assert messages are `[user: "Hello", assistant: "Hello world"]`, status is `.completed`, `error == nil`, and timestamps are populated.

```swift
XCTAssertEqual(service.state.messages.map(\.role), [.user, .assistant])
XCTAssertEqual(service.state.messages[1].text, "Hello world")
XCTAssertEqual(service.state.status, .completed)
```

- [ ] **Step 2: Run RED, then implement minimal stream consumption**

Run: `swift test --filter AgentSessionServiceTests/testStreamingDeltasBuildOneAssistantMessage`
Expected RED before implementation. Implement only enough to build one assistant message, map tool/waiting events, require `.completed`, and mark a clean stream that ends without `.completed` as `.failed` / `.streamInterrupted`.

- [ ] **Step 3: Add failing cancellation test**

Use `AsyncThrowingStream.makeStream(of:)` in `TestProviderRuntime` so the returned `ProviderStream.cancel` closure records cancellation in an actor probe and finishes the continuation with `CancellationError`. Start a turn, wait until at least one partial delta is observed, call `await service.cancel()`, and assert `.cancelled`, provider cancellation count `1`, and no later yielded event can change the cancelled state.

- [ ] **Step 4: Run RED, implement cancellation, then GREEN**

Run: `swift test --filter AgentSessionServiceTests/testCancellationCancelsProviderStreamAndRejectsStaleEvents`
Expected RED before implementation, PASS after. Use an active turn UUID/generation guard so events from an invalidated turn cannot mutate current state.

- [ ] **Step 5: Add failing error-normalization tests**

Verify a runtime that throws while starting the stream produces `.failed` / `.transportFailure` without putting the runtime error string into `AgentSessionState`. Verify a stream ending without `.completed` produces `.streamInterrupted`.

- [ ] **Step 6: Run focused GREEN and regression tests**

Run: `swift test --filter AgentSessionServiceTests && swift test --filter ProviderCapabilitiesTests`
Expected: PASS.

---

### Task 4: Bind the native chat presentation to the core

**Files:**
- Modify: `Sources/AgenticSidebar/App/AgenticSidebarApp.swift`
- Modify: `Sources/AgenticSidebar/Models/SessionPresentationState.swift`
- Modify: `Sources/AgenticSidebar/Views/RootChatView.swift`
- Modify: `Sources/AgenticSidebar/Views/ConversationDetailView.swift`
- Modify: `Sources/AgenticSidebar/Views/ComposerView.swift`
- Modify: `Sources/AgenticSidebar/Views/MenuBarSessionView.swift`
- Remove after successful compile: `Sources/AgenticSidebar/Stores/SessionPresentationStore.swift`
- Modify test: `Tests/AgenticSidebarTests/SessionPresentationStateTests.swift`

**Interfaces:**
- `AgenticSidebarApp` owns one process-lifetime `AgentSessionService(runtimes: [])` until M3/M4 inject concrete adapters.
- `SessionPresentationState.init(agentSessionState:)` maps core status/timestamps to the existing menu-bar presentation model.
- `SessionPhase` adds `cancelling`, `cancelled`, and `failed` so menu-bar state does not mislabel those core states.
- `RootChatView`, `ConversationDetailView`, `ComposerView`, and `MenuBarSessionView` receive the same service instance; no window-owned session state is introduced.

- [ ] **Step 1: Write failing presentation-mapping tests**

Extend `SessionPhase` test-first with `.cancelling`, `.cancelled`, and `.failed`, then verify `.streaming -> .thinking`, `.runningTool("Search") -> .runningTool("Search")`, `.waiting -> .waiting`, `.cancelling -> .cancelling`, `.completed -> .completed`, `.cancelled -> .cancelled`, and `.failed -> .failed`. Verify `startedAt` / `completedAt` copy from the core state and add exact titles/symbol assertions for the three new phases.

- [ ] **Step 2: Run RED, implement mapping, run GREEN**

Run: `swift test --filter SessionPresentationStateTests`
Expected RED before initializer exists, PASS after.

- [ ] **Step 3: Replace the shell-only session store with process-owned `AgentSessionService`**

Initialize `@State private var sessionService = AgentSessionService(runtimes: [])` in `AgenticSidebarApp`. Pass it into the main window and menu-bar views. Remove `SessionPresentationStore` only after all references are gone and the build succeeds.

- [ ] **Step 4: Render provider-neutral chat state**

`ConversationDetailView` renders `service.state.messages` with distinct user/assistant alignment, an empty state when no messages exist, and compact provider/model/variant `Picker` controls populated from `service.providers`, `availableModels`, and `availableVariants`. Disable configuration controls while `service.isBusy`. With zero runtimes, show a truthful unavailable-provider state rather than a fake/demo provider.

- [ ] **Step 5: Wire composer submit/cancel behavior**

`ComposerView` accepts the shared service. Send is enabled only when trimmed draft text is non-empty and `service.canSubmit == true`; submitting clears the draft only when `service.submit` returns a non-`nil` task. While a turn is active, present a cancel control that invokes `Task { await service.cancel() }`. Do not create a view-owned stream consumer task.

- [ ] **Step 6: Compile before any visual refinement**

Run: `swift build --product AgenticSidebar`
Expected: exit 0. Fix only integration/compiler issues required by the approved M2 design.

---

### Task 5: M2 verification, host smoke check, and local commit

**Files:**
- Verify all M2 source/test files above.
- Update continuity/task state with exact HEAD and verification evidence.
- Do not commit screenshots, `.build`, `dist`, or local runtime artifacts.

- [ ] **Step 1: Run fresh full automated verification**

Run: `swift test`
Expected: all M1 + M2 tests pass with zero failures.

Run: `swift build --product AgenticSidebar`
Expected: exit 0.

Run: `./script/build_and_run.sh --verify`
Expected: exit 0 and the staged `.app` remains launchable.

- [ ] **Step 2: Real-host M1 regression smoke**

Verify the app still launches Dock-less, Command-B still hides/shows and activates after reopen, Command-W does not terminate the process, Settings still opens, and the menu-bar toggle still removes/reinserts the extra. These are regression checks; do not re-characterize capture privacy unless capture code changed.

- [ ] **Step 3: Real-host M2 presentation smoke**

Verify the main window renders the M2 chat surface without crashing, shows no fabricated provider when the runtime list is empty, and disables submission until a provider adapter is injected. The menu-bar status must remain derived from the same process-owned session service.

- [ ] **Step 4: Inspect final status/diff**

Run the repository status/diff tools. Confirm only the M2 plan/core/tests/UI integration are changed and no user/other-agent changes were overwritten.

- [ ] **Step 5: Stage explicit M2 paths and create one logical local commit**

Commit message: `feat: add provider-neutral chat session core`

Do not push.

# AgenticSidebar M3 Direct OpenAI Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task-by-task. Every production behavior starts from a failing XCTest.

**Goal:** Add a direct OpenAI Responses API backend with Keychain-only credentials, dynamic accessible-model discovery, verified model-specific reasoning-effort choices, SSE streaming, cancellation, and Settings integration.

**Architecture:** Keep AgentCore provider-neutral. Add CredentialStore and OpenAIProvider source boundaries inside the existing SwiftPM target. `OpenAIProviderRuntime` implements `ProviderRuntime`; it loads the API key from `CredentialStore`, gets accessible IDs from `GET /v1/models`, intersects them with a conservative verified capability catalog, and streams `POST /v1/responses` events into existing `ProviderEvent` values. No OpenAI transport types enter Views or AgentCore.

**Tech Stack:** Swift 6.3, Foundation/URLSession, Security.framework Keychain APIs, AsyncThrowingStream, XCTest, macOS 26.0.

**Spec:** `docs/superpowers/specs/2026-09-15-agentic-sidebar-design.md`

## Global Constraints

- API keys live only in Keychain; never UserDefaults, source, fixtures, logs, snapshots, or continuity records.
- `GET /v1/models` provides availability/basic metadata, not reasoning-effort capability metadata; unknown model IDs receive no invented capability.
- Initial verified catalog: `gpt-6-astra` => low/medium/high/xhigh/max; `gpt-5.6`/`gpt-5.6-sol`/`gpt-5.6-terra`/`gpt-5.6-luna` => none/low/medium/high/xhigh/max.
- If both `gpt-5.6` and `gpt-5.6-sol` are returned, prefer the `gpt-5.6` alias and do not show duplicate Sol entries.
- Responses streaming maps `response.output_text.delta` to `.assistantTextDelta` and `response.completed` to `.completed`; refusal deltas are surfaced as assistant text. Failed/incomplete/error terminal events fail safely.
- No real API call is required unless an application-owned credential is already present or the user explicitly supplies one.
- Preserve M1/M2 host behavior and do not push.

---

### Task 1: Provider-neutral runtime error categories

**Files:**
- Modify: `Sources/AgenticSidebar/ProviderGateway/ProviderRuntime.swift`
- Modify: `Sources/AgenticSidebar/AgentCore/AgentSessionState.swift`
- Modify: `Sources/AgenticSidebar/AgentCore/AgentSessionService.swift`
- Modify: `Tests/AgenticSidebarTests/AgentSessionServiceTests.swift`

**Produces:** `ProviderRuntimeError` cases `missingCredential`, `unavailable`, `transport`, `unexpectedResponse`; `AgentSessionError.missingCredential`.

- [ ] Add failing tests that a missing-credential runtime maps to `.missingCredential`, unavailable maps to `.providerUnavailable`, and unexpected response maps to `.unexpectedBackendResponse` without storing raw provider error text.
- [ ] Run `swift test --filter AgentSessionServiceTests` and observe RED.
- [ ] Add `ProviderRuntimeError` and minimal mapping in capability refresh/start-stream catch paths.
- [ ] Re-run focused tests to GREEN.

### Task 2: Keychain credential boundary

**Files:**
- Create: `Sources/AgenticSidebar/CredentialStore/CredentialStore.swift`
- Create: `Sources/AgenticSidebar/CredentialStore/KeychainCredentialStore.swift`
- Test: `Tests/AgenticSidebarTests/KeychainCredentialStoreTests.swift`

**Produces:**
```swift
enum CredentialKey: String, Sendable { case openAIAPIKey = "openai.api-key" }
protocol CredentialStore: Sendable {
    func contains(_ key: CredentialKey) throws -> Bool
    func read(_ key: CredentialKey) throws -> String?
    func write(_ value: String, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
}
```

- [ ] Write a failing round-trip test using a unique Keychain service name and a runtime-generated value; cleanup with `defer`; assertions must not print the value.
- [ ] Run `swift test --filter KeychainCredentialStoreTests` and observe RED.
- [ ] Implement generic-password Keychain queries with `kSecAttrService` + `kSecAttrAccount`; update existing items rather than creating duplicates; treat item-not-found as nil/false.
- [ ] Run focused test to GREEN.

### Task 3: Verified OpenAI model capability catalog

**Files:**
- Create: `Sources/AgenticSidebar/OpenAIProvider/OpenAIModelCatalog.swift`
- Test: `Tests/AgenticSidebarTests/OpenAIModelCatalogTests.swift`

**Produces:** ordered `ProviderModelCapability` values only for API-returned IDs known to the verified catalog.

- [ ] Write RED tests for Astra effort list, GPT-5.6 effort list, unknown-ID exclusion, and `gpt-5.6` alias preference over `gpt-5.6-sol`.
- [ ] Implement the minimal catalog with display names and `ProviderVariantID` values matching API `reasoning.effort` strings exactly.
- [ ] Run focused tests GREEN.

### Task 4: OpenAI HTTP transport and SSE decoding

**Files:**
- Create: `Sources/AgenticSidebar/OpenAIProvider/OpenAITransport.swift`
- Create: `Sources/AgenticSidebar/OpenAIProvider/OpenAIResponsesRequest.swift`
- Create: `Sources/AgenticSidebar/OpenAIProvider/OpenAIStreamDecoder.swift`
- Test: `Tests/AgenticSidebarTests/OpenAIStreamDecoderTests.swift`
- Test support: `Tests/AgenticSidebarTests/TestOpenAITransport.swift`

**Interfaces:**
```swift
struct OpenAIHTTPResponse: Sendable { let statusCode: Int; let data: Data }
struct OpenAILineStream: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () async -> Void
}
protocol OpenAITransport: Sendable {
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse
    func stream(_ request: URLRequest) async throws -> OpenAILineStream
}
```

- [ ] RED: decoder maps output-text deltas and refusal deltas to assistant text, completion to `.completed`, ignores unrelated events, and throws for failed/incomplete/error events.
- [ ] GREEN: parse only `data:` SSE JSON payloads by `type`; never log payloads.
- [ ] RED: request encoding test verifies `model`, conversation messages, `stream=true`, and optional `{reasoning:{effort:...}}`; no Authorization value is embedded in Codable payload.
- [ ] Implement URLSession transport using `data(for:)` and `bytes(for:)`; cancellation stops the forwarding task/byte iteration.

### Task 5: Concrete OpenAI ProviderRuntime

**Files:**
- Create: `Sources/AgenticSidebar/OpenAIProvider/OpenAIProviderRuntime.swift`
- Test: `Tests/AgenticSidebarTests/OpenAIProviderRuntimeTests.swift`

**Behavior:** provider ID `openai`; capabilities require a Keychain credential, call `/v1/models`, decode IDs, intersect with `OpenAIModelCatalog`; stream requests use `/v1/responses` and the selected model/effort.

- [ ] RED: no credential -> `ProviderRuntimeError.missingCredential` without transport calls.
- [ ] RED: model discovery filters unknown/unavailable IDs and preserves catalog order.
- [ ] RED: startStream constructs Bearer-authenticated request, maps SSE events to ProviderEvents, and ProviderStream.cancel invokes transport cancellation exactly once.
- [ ] Implement minimally and run `swift test --filter OpenAIProviderRuntimeTests` GREEN.

### Task 6: Settings and application wiring

**Files:**
- Modify: `Sources/AgenticSidebar/App/AgenticSidebarApp.swift`
- Modify: `Sources/AgenticSidebar/Views/SettingsView.swift`
- Create: `Sources/AgenticSidebar/Views/OpenAICredentialSettingsView.swift`

- [ ] App owns one `KeychainCredentialStore` and injects one `OpenAIProviderRuntime` into the process-owned `AgentSessionService`.
- [ ] Settings shows only credential presence, an ephemeral `SecureField`, Save, and Remove. Never prefill/read the stored secret into UI.
- [ ] Save trims input, writes Keychain, clears draft, and triggers provider capability refresh; Remove deletes and refreshes.
- [ ] Build before visual refinement: `swift build --product AgenticSidebar`.
- [ ] Host-smoke Settings save/remove UI only with a generated disposable credential if needed; do not perform a real API request with fake credentials.

### Task 7: Full verification and local commit

- [ ] Fresh `swift test`; expect all M1/M2/M3 tests 0 failures.
- [ ] Fresh `swift build --product AgenticSidebar`.
- [ ] `./script/build_and_run.sh --verify`; process must exist.
- [ ] Host regressions: Dock absent, Command-B hide/show, Command-W process survival/reopen, MenuBarExtra present, Settings opens.
- [ ] Verify Settings accurately reports whether the application Keychain credential exists; do not print/read the value.
- [ ] If no real application credential exists, record real API smoke as intentionally not run. If one exists, run one minimal opt-in Responses smoke without logging authorization or response bodies beyond success metadata.
- [ ] Inspect status/diff; stage explicit M3 paths; commit locally as `feat: add direct OpenAI provider adapter`; do not push.

# Architecture-Driven Implementation Plan

## Accepted decisions
- ADR-001: Native modular macOS architecture with provider ports.
- ADR-002: Direct OpenAI plus managed-local OpenCode backends.
- ADR-003: Native menu-bar/accessory behavior plus best-effort capture privacy.
- Architecture contract revision: 1.

## Milestones

### M0 — Host and toolchain verification
Outcome: establish the real implementation baseline before creating application code.
Scope: Xcode version, Swift version, installed macOS SDKs, current macOS version, Git state, OpenCode executable/version if present.
Constraints: no assumptions from the Linux sandbox may be treated as host verification.
Verification: record exact tool outputs and chosen deployment target.

### M1 — Native application shell
Outcome: launchable Dock-less macOS application with Liquid Glass shell, primary chat window, Settings entry point, optional MenuBarExtra surface, and Command-B show/hide behavior.
Scope: app-shell, settings-store, capture-privacy boundary.
Constraints: use system Liquid Glass APIs; AppKit interop remains narrow; capture privacy is labeled best-effort.
Verification: build/tests plus real-host checks for Dock, menu bar, shortcut, hide/show, and basic capture behavior.

### M2 — Provider-neutral chat/session core
Outcome: provider-neutral conversation state and streaming/cancellation pipeline independent of concrete backends.
Scope: agent-core, provider-port, chat-presentation.
Constraints: structured concurrency and explicit cancellation; provider-specific types do not leak into presentation.
Verification: unit tests for state transitions, stream normalization, cancellation, model capability filtering, and backend switching.

### M3 — Direct OpenAI adapter
Outcome: API-key configuration, dynamic model/effort selection, and streaming direct OpenAI chat through the Responses API.
Scope: openai-adapter, credential-store, settings integration.
Constraints: Keychain-only secret persistence; supported effort levels are capability-driven.
Verification: mocked transport tests plus opt-in real API smoke test only when a user credential is present.

### M4 — OpenCode adapter
Outcome: detect an existing OpenCode executable, start a protected loopback server when requested, discover providers/models/variants, configure credentials through supported APIs, create sessions, send prompts, consume SSE events, and surface status in the same chat UI.
Scope: opencode-adapter, credential-store, agent-core integration.
Constraints: no silent binary download; server bound to 127.0.0.1 and authenticated; process termination is explicit.
Verification: adapter contract tests plus host integration against the installed OpenCode version.

### M5 — Integrated acceptance pass
Outcome: first milestone behaves coherently with both backends and background operation.
Scope: complete application.
Constraints: do not report unsupported capture guarantees.
Verification: clean build, unit/integration suite, launch on real macOS host, backend switching, model/effort selection, background session continuity, menu-bar status, Command-B toggle, Dock absence, and documented capture test matrix.

## Cross-cutting constraints
- User secrets must never appear in source control, normal application logs, UserDefaults, snapshots, or test fixtures.
- Managed OpenCode networking is loopback-only for the first milestone.
- Concurrency ownership must make cancellation and UI isolation explicit.
- Platform-specific private/unsupported APIs are not used to fake capture guarantees or Dynamic Island behavior.
- Verification distinguishes compile/test success from real macOS behavioral validation.

## Explicit non-goals
- iOS companion and ActivityKit Live Activity.
- Cloud transcript sync or user accounts.
- Third-party providers implemented directly outside OpenCode.
- Autonomous host computer control beyond the OpenCode session capabilities exposed in this milestone.
- Automatic OpenCode installation or self-update.

## Unresolved questions
- M0 resolves the exact host Xcode, Swift, macOS SDK, and OpenCode versions before scaffolding.

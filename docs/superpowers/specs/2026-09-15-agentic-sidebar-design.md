# AgenticSidebar — First Milestone Design

Date: 2026-09-15
Status: Approved architecture; written specification pending final review before implementation.

## Product objective
AgenticSidebar is a native personal macOS agent application centered on a sidebar-style chat window. It runs as an accessory/background utility, exposes current session state in the macOS menu bar when enabled, and supports direct OpenAI or OpenCode execution selected per session.

## Native macOS shell
The application is SwiftUI-first with narrow AppKit interop for activation policy, primary-window control, global shortcut behavior, and platform functions not sufficiently exposed by SwiftUI. It uses the latest stable macOS SDK available on the host and current Liquid Glass APIs rather than custom translucent-window emulation.

The application does not show a normal Dock icon. Command-B is the default global toggle for showing and hiding the main conversation window. The shortcut is represented as a setting so later customization does not require reworking the window controller.

When enabled, a MenuBarExtra-style surface reflects active session state while the main window is hidden or backgrounded. This is intentionally the native macOS interpretation of the requirement rather than a simulated iPhone Dynamic Island. Disabling the menu-bar feature affects presentation only; it does not terminate a running session.

## Chat and session model
The chat presentation sends user intents to an AgentSessionService owned by the provider-neutral core. Core state includes selected backend, selected model, optional effort/variant, current messages, streaming state, status, cancellation state, and error state.

Provider-specific networking and event types terminate at adapters. UI code receives normalized capabilities and normalized streamed events so the same conversation surface is used for direct OpenAI and OpenCode.

Changing provider/model/effort is permitted through the UI. Unsupported effort levels are not shown. A session may preserve its selected configuration independently of the global defaults.

## Direct OpenAI backend
The direct OpenAI adapter uses the Responses API and streaming. The API credential is application-owned and stored only in macOS Keychain. Model and reasoning choices are capability-driven so the UI does not assume every OpenAI model supports the same effort levels.

## OpenCode backend
OpenCode is treated as a local agent runtime. The application first diagnoses whether the OpenCode executable is available. The first milestone does not silently install or update OpenCode.

For managed-local operation the app launches `opencode serve` bound to 127.0.0.1 with server authentication. It checks server health, discovers providers and models, reads provider auth methods, sends credential updates through the documented auth API, creates sessions, submits prompts, reads status, and consumes server-sent events. OpenCode provider credentials remain owned by OpenCode after submission; the app does not copy them into UserDefaults.

The adapter must tolerate process exit, HTTP failure, SSE disconnect, session cancellation, and backend restart without corrupting the UI state.

## Concurrency
UI-observable state is isolated to the main actor. Network streams, OpenCode process monitoring, and event decoding use structured concurrency. Long-lived work is represented by owned tasks with explicit cancellation. Detached tasks are avoided unless there is a demonstrated lifetime boundary that cannot be modeled structurally.

## Capture privacy
Capture protection is implemented behind a dedicated controller and is explicitly best-effort. Availability-checked supported techniques may be applied, and the app's own ScreenCaptureKit usage must exclude its own window where applicable. The product never claims guaranteed invisibility from macOS screenshots or arbitrary third-party capture tools. Actual behavior is recorded in a host-level capture test matrix.

## Error handling
Errors are normalized into user-actionable categories: missing credential, unsupported capability, provider unavailable, OpenCode executable unavailable, OpenCode startup/auth failure, transport failure, stream interruption, cancellation, and unexpected backend response. Secret values and request authorization material never enter user-visible diagnostics or standard logs.

## Verification strategy
Each milestone distinguishes four evidence classes: compile success, automated unit tests, backend integration tests, and real-host macOS behavior. The first milestone is complete only after the target host has verified Dock absence, Command-B global toggle, menu-bar state, background session continuity, both backend paths, dynamic model/effort selection, Keychain persistence, and the documented limits of capture protection.

## First milestone completion boundary
The milestone includes the native shell, Liquid Glass chat interface, Settings, Dock-less behavior, Command-B toggle, optional live menu-bar session surface, provider-neutral chat core, direct OpenAI streaming, managed-local OpenCode integration, dynamic model/effort selection, Keychain-backed application secrets, and best-effort capture privacy.

It excludes an iOS companion, ActivityKit-originated Live Activity, cloud sync, additional direct providers, silent OpenCode installation, and stronger capture guarantees than the operating system provides.

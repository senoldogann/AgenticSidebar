# AgenticSidebar M1 Native Application Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first runnable AgenticSidebar macOS shell as a Dock-less native SwiftUI application with a sidebar chat surface, Settings, optional menu-bar session presence, global Command-B show/hide, Liquid Glass presentation, and a truthful best-effort capture-privacy boundary.

**Architecture:** Use one SwiftPM executable target for the native SwiftUI/AppKit app and one XCTest target. App-wide settings and session-presentation state live outside the main window so hiding the window does not destroy session state. AppKit/Carbon interop is restricted to application activation, NSWindow control, and RegisterEventHotKey; capture privacy deliberately avoids deprecated NSWindow sharing flags that Apple documents as unsuitable for capture hiding.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Observation, Carbon.HIToolbox, XCTest, macOS 26.0 deployment target.

**Spec:** `docs/superpowers/specs/2026-09-15-agentic-sidebar-design.md`

## Global Constraints

- Native macOS application; SwiftUI-first with narrow AppKit interop.
- Minimum deployment target: macOS 26.0, derived from the verified implementation host and current Liquid Glass requirement.
- Swift language mode: Swift 6.
- No third-party runtime or UI dependency.
- No Dock icon during normal operation.
- Command-B is the default global show/hide shortcut.
- Menu-bar session presentation is user-toggleable and must not own session lifetime.
- Capture privacy is explicitly best-effort and must not use `NSWindow.SharingType.none` as a security guarantee.
- Secrets are not introduced in M1.
- Every behavior-bearing production type is introduced through a failing XCTest first when practical; AppKit/Carbon host integration is additionally verified on the real Mac.

---

### Task 1: Repository and SwiftPM GUI bootstrap

**Files:**
- Create: `Package.swift`
- Create: `script/build_and_run.sh`
- Create: `.codex/environments/environment.toml`
- Create: `Sources/AgenticSidebar/Support/AppIdentity.swift`
- Test: `Tests/AgenticSidebarTests/AppIdentityTests.swift`

**Interfaces:**
- Produces: `enum AppIdentity { static let name: String; static let bundleIdentifier: String; static let minimumSystemVersion: String }`

- [ ] **Step 1: Write the failing identity test**

```swift
import XCTest
@testable import AgenticSidebar

final class AppIdentityTests: XCTestCase {
    func testIdentityMatchesBundleContract() {
        XCTAssertEqual(AppIdentity.name, "AgenticSidebar")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.dogan.AgenticSidebar")
        XCTAssertEqual(AppIdentity.minimumSystemVersion, "26.0")
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter AppIdentityTests`
Expected: build failure because the executable target / `AppIdentity` does not exist yet.

- [ ] **Step 3: Add minimal package and identity implementation**

`Package.swift` declares macOS 26, one executable target named `AgenticSidebar`, and one test target. `AppIdentity.swift` defines exactly the constants asserted above.

- [ ] **Step 4: Add the GUI build/run harness**

`script/build_and_run.sh` must stop an existing `AgenticSidebar`, run `swift build --product AgenticSidebar`, stage `dist/AgenticSidebar.app`, create an Info.plist with `LSUIElement=true`, copy the binary, and launch via `/usr/bin/open -n`. `--verify` additionally confirms the process is alive with `pgrep -x AgenticSidebar`. `.codex/environments/environment.toml` exposes `./script/build_and_run.sh` as the Run action.

- [ ] **Step 5: Run tests and build**

Run: `swift test --filter AppIdentityTests && swift build --product AgenticSidebar`
Expected: PASS / exit 0 after a minimal app entry point is added in the next task; until then the package may only prove target structure.

---

### Task 2: Persistent settings and session presentation state

**Files:**
- Create: `Sources/AgenticSidebar/Stores/SettingsStore.swift`
- Create: `Sources/AgenticSidebar/Models/SessionPresentationState.swift`
- Create: `Sources/AgenticSidebar/Stores/SessionPresentationStore.swift`
- Test: `Tests/AgenticSidebarTests/SettingsStoreTests.swift`
- Test: `Tests/AgenticSidebarTests/SessionPresentationStateTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class SettingsStore` with `menuBarSessionEnabled: Bool` backed by an injected `UserDefaults`.
- Produces: `enum SessionPhase: Equatable, Sendable { case idle, thinking, runningTool(String), waiting, completed }`.
- Produces: `struct SessionPresentationState: Equatable, Sendable` with `phase`, `startedAt`, `completedAt`, `statusTitle`, `symbolName`, and `elapsed(at:)`.
- Produces: `@MainActor @Observable final class SessionPresentationStore { var state: SessionPresentationState }`.

- [ ] **Step 1: Write failing settings tests**

Test the default `menuBarSessionEnabled == true`, mutation persistence into an isolated `UserDefaults(suiteName:)`, and reload behavior.

- [ ] **Step 2: Run focused settings tests and verify RED**

Run: `swift test --filter SettingsStoreTests`
Expected: compile failure because `SettingsStore` does not exist.

- [ ] **Step 3: Implement the minimal settings store and verify GREEN**

Persist only the non-secret menu-bar preference in M1. Remove the isolated suite in `tearDown`.

- [ ] **Step 4: Write failing session-state tests**

Assert titles for `.thinking`, `.runningTool("Search")`, `.waiting`, `.completed`, and elapsed-time clamping before `startedAt` plus freezing at `completedAt`.

- [ ] **Step 5: Run focused session tests and verify RED, then implement and verify GREEN**

Run: `swift test --filter SessionPresentationStateTests` before and after implementation.

---

### Task 3: Window lifecycle and global Command-B shortcut

**Files:**
- Create: `Sources/AgenticSidebar/Services/MainWindowController.swift`
- Create: `Sources/AgenticSidebar/Services/GlobalHotKeyController.swift`
- Create: `Sources/AgenticSidebar/Views/WindowLifecycleBridge.swift`
- Test: `Tests/AgenticSidebarTests/MainWindowControllerTests.swift`
- Test: `Tests/AgenticSidebarTests/GlobalShortcutSpecTests.swift`

**Interfaces:**
- Produces: `@MainActor final class MainWindowController` that registers one NSWindow, configures close-to-hide behavior, exposes `toggle()`, `show()`, and `hide()`.
- Produces: `struct GlobalShortcutSpec: Equatable, Sendable` with default Carbon keyCode `kVK_ANSI_B` and modifiers `cmdKey`.
- Produces: `@MainActor final class GlobalHotKeyController` that owns one Carbon `EventHotKeyRef` and invokes a supplied main-actor action.
- Produces: `WindowLifecycleBridge(windowController:capturePrivacyController:)` as the narrow SwiftUI-to-NSWindow bridge.

- [ ] **Step 1: Write failing shortcut-spec and window visibility tests**

Verify the default shortcut is Command-B. Instantiate an NSWindow and assert `hide()` orders it out and `show()` orders it front when registered.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter GlobalShortcutSpecTests` and `swift test --filter MainWindowControllerTests`.

- [ ] **Step 3: Implement minimal window controller and verify GREEN**

Use `NSWindowDelegate.windowShouldClose` to convert the close button into `orderOut(nil)` without terminating app/session state.

- [ ] **Step 4: Implement Carbon hot-key registration**

Use `RegisterEventHotKey` / `InstallEventHandler` from `Carbon.HIToolbox`; do not require Accessibility/Input Monitoring permissions. Own and unregister the hot-key and event handler on deinit.

- [ ] **Step 5: Build and run focused tests**

Run: `swift test --filter GlobalShortcutSpecTests && swift test --filter MainWindowControllerTests && swift build --product AgenticSidebar`.

---

### Task 4: SwiftUI app shell, Settings, MenuBarExtra, and Liquid Glass

**Files:**
- Create: `Sources/AgenticSidebar/App/AgenticSidebarApp.swift`
- Create: `Sources/AgenticSidebar/App/AppDelegate.swift`
- Create: `Sources/AgenticSidebar/Views/RootChatView.swift`
- Create: `Sources/AgenticSidebar/Views/ConversationSidebarView.swift`
- Create: `Sources/AgenticSidebar/Views/ConversationDetailView.swift`
- Create: `Sources/AgenticSidebar/Views/SettingsView.swift`
- Create: `Sources/AgenticSidebar/Views/MenuBarSessionView.swift`

**Interfaces:**
- `AgenticSidebarApp` owns `SettingsStore`, `SessionPresentationStore`, `MainWindowController`, `GlobalHotKeyController`, and `CapturePrivacyController` for the process lifetime.
- `WindowGroup("AgenticSidebar", id: "main")` hosts the primary UI.
- `Settings` hosts `SettingsView`.
- `MenuBarExtra(..., isInserted: $settings.menuBarSessionEnabled)` hosts `MenuBarSessionView` with `.menuBarExtraStyle(.window)`.

- [ ] **Step 1: Add the minimal `@main` app composition**

AppDelegate calls `NSApp.setActivationPolicy(.accessory)`. Root app state is process-owned rather than window-owned.

- [ ] **Step 2: Build and fix only compile-time integration issues**

Run: `swift build --product AgenticSidebar`.
Expected: exit 0 before visual refinements.

- [ ] **Step 3: Add native desktop layout**

Use `NavigationSplitView` with a lightweight session/sidebar column and a detail conversation empty state. Keep toolbar/sidebar system materials; do not paint custom opaque backgrounds.

- [ ] **Step 4: Add Liquid Glass only to app-specific floating status/composer surfaces**

Use `glassEffect` / system controls on macOS 26. Avoid custom blur recreation.

- [ ] **Step 5: Add Settings and menu-bar presentation**

Settings toggles `menuBarSessionEnabled`. Menu bar content reads the shared session store and uses `TimelineView` for elapsed time without creating a long-lived timer task.

---

### Task 5: Truthful capture-privacy boundary

**Files:**
- Create: `Sources/AgenticSidebar/Services/CapturePrivacyController.swift`
- Test: `Tests/AgenticSidebarTests/CapturePrivacyControllerTests.swift`

**Interfaces:**
- Produces: `struct CapturePrivacyCapabilities: Equatable, Sendable` with `externalCaptureExclusionGuaranteed == false`, `supportsSelfCaptureFiltering == true`, and a user-visible limitation string.
- Produces: `@MainActor final class CapturePrivacyController` with `capabilities` and `configure(window:) -> CapturePrivacyReport`.
- `configure(window:)` intentionally does not set `NSWindow.sharingType = .none` because current Apple documentation states that value is legacy and should not be used to omit content from capture.

- [ ] **Step 1: Write the failing policy test**

Assert the controller never reports guaranteed external exclusion and reports self-capture filtering as available through ScreenCaptureKit filters.

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter CapturePrivacyControllerTests`.

- [ ] **Step 3: Implement the truthful capability report and verify GREEN**

No private API, no deprecated capture-hiding claim, and no legacy sharing flag mutation.

---

### Task 6: Full verification and first logical commits

**Files:**
- Verify all files above.
- Record runtime evidence in the project continuity checkpoint; do not commit screenshots or local artifacts.

- [ ] **Step 1: Run full automated verification**

Run: `swift test` and `swift build --product AgenticSidebar`.
Expected: zero test failures and exit 0.

- [ ] **Step 2: Build and launch the real `.app` bundle**

Run: `./script/build_and_run.sh --verify`.
Expected: bundle launches and process remains alive.

- [ ] **Step 3: Real-host interaction checks**

Verify separately: Dock icon absence, initial main window, Command-B hide/show while another app is frontmost, Settings menu-bar toggle, menu-bar state surface, close-to-hide behavior, and that hiding the window does not destroy the shared session store.

- [ ] **Step 4: Capture behavior check**

Take at least one host screenshot/capture path while the window is visible. Record whether AgenticSidebar is present; do not convert the observation into a broader guarantee.

- [ ] **Step 5: Commit verified logical units locally**

Use small commits for baseline architecture/repo setup and M1 implementation. Do not push.

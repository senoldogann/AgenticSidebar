# AgenticSidebar Project Context

## Purpose
Build a native personal macOS agent application with a sidebar-style chat experience, native Liquid Glass presentation, background session continuity, optional menu-bar session presence, global show/hide shortcut, best-effort capture privacy, and runtime-selectable OpenAI/OpenCode backends.

## Confirmed product requirements
- Native macOS application built primarily with SwiftUI and targeted AppKit interop only where SwiftUI does not provide the required desktop behavior.
- Latest stable macOS SDK available on the implementation host is the target baseline; exact deployment target is verified from installed Xcode before project creation.
- Liquid Glass uses current system APIs instead of a custom blur recreation.
- The app runs without a Dock icon and can be shown or hidden with Command-B by default.
- When enabled by the user, an active background session is represented in the macOS menu bar; this is a native MenuBarExtra-style experience, not an emulated iPhone Dynamic Island.
- Screen-capture hiding is best-effort only. The product must not claim guaranteed exclusion from system screenshots or arbitrary third-party recorders.
- Direct OpenAI and OpenCode are selectable execution backends.
- Provider, model, and supported reasoning/effort level are selected dynamically in the UI.
- User-entered direct OpenAI credentials are stored in Keychain, not UserDefaults or source-controlled files.
- OpenCode credentials entered through the app are forwarded through OpenCode's supported auth API; the app does not duplicate them into plaintext application settings.

## External interface facts verified on 2026-09-15
- SwiftUI MenuBarExtra supports binding-controlled insertion and window-style menu-bar presentation.
- OpenCode exposes localhost HTTP APIs for provider discovery, provider auth methods, credential update, session lifecycle, async prompting, status, and SSE events.
- OpenCode server authentication can be protected with OPENCODE_SERVER_PASSWORD and binds to 127.0.0.1 by default.
- OpenCode model variants expose model-specific reasoning choices; unsupported variants must not be invented by the client.
- Current OpenAI models expose model-specific reasoning effort choices through the Responses API; the client must derive allowed choices from model capabilities rather than hard-code one universal set.

## Quality priorities
1. Native macOS integration and predictable desktop behavior.
2. Credential safety and local-boundary security.
3. Correct cancellation/streaming/session lifecycle behavior.
4. Provider/model extensibility without coupling UI to one backend.
5. Feature-by-feature verifiability on the real macOS host.

## Explicit non-goals for the first milestone
- iOS companion application or ActivityKit Live Activity originating from an iPhone app.
- Guaranteed DRM-style exclusion from every screenshot or recording path.
- Cloud account sync, multi-device transcript sync, team collaboration, or billing.
- Additional LLM backends beyond direct OpenAI and OpenCode.
- Autonomous computer-use/tool execution beyond what OpenCode itself exposes in the selected session.

---
schema_version: 1.0.0
revision: 1
decision:
  id: ADR-003
  title: Use native menu-bar presence and best-effort capture privacy
  status: accepted
  context: AgenticSidebar should stay out of the Dock, be globally summonable, optionally show live session state while hidden, and reduce capture visibility without claiming unsupported guarantees.
  drivers:
    - Match native macOS interaction conventions.
    - Preserve active agent sessions when the main window is hidden.
    - Avoid presenting an emulated iPhone Dynamic Island as a native Mac feature.
    - Make privacy behavior truthful and testable against supported capture paths.
  considered_option_ids:
    - OPT-007
    - OPT-008
    - OPT-009
  selected_option_id: OPT-007
  decision: Run as an accessory-style app without a Dock icon, expose a user-toggleable MenuBarExtra session surface, use Command-B as the default global show/hide shortcut, and isolate capture protection behind a best-effort controller with explicit capability limitations.
  positive_consequences:
    - The app behaves like a native background macOS utility.
    - Active session status remains visible without keeping the main window open.
    - Capture privacy can evolve without contaminating chat or session logic.
  negative_consequences:
    - Global shortcut and window activation require AppKit-level integration and real-device testing.
    - Capture exclusion cannot be promised for every system or third-party recording path.
  assumptions:
    - MenuBarExtra is the appropriate native macOS presentation for the first milestone.
    - Best-effort capture techniques will be guarded by availability and verified behavior on the target macOS build.
  validation_criteria:
    - No Dock icon is shown during normal operation.
    - Command-B toggles the primary window from both active and background states on the implementation host.
    - Disabling the menu-bar-session setting removes the optional session surface without cancelling the active session.
    - Capture-privacy tests document which tested capture paths exclude or include the app window.
  supersedes: []
---

# ADR-003: Use native menu-bar presence and best-effort capture privacy

Accepted option OPT-007 uses native macOS accessory application behavior, optional MenuBarExtra session presentation, a global Command-B toggle, and an explicitly best-effort capture-privacy boundary.

- OPT-007: Native menu-bar/accessory behavior with best-effort capture privacy.
- OPT-008: Conventional Dock application with no capture-privacy boundary.
- OPT-009: Custom notch/Dynamic-Island emulation.

The selected option prioritizes native macOS conventions and avoids unsupported privacy or UI claims.

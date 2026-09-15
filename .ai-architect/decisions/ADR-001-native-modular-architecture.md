---
schema_version: 1.0.0
revision: 1
decision:
  id: ADR-001
  title: Use a native modular macOS architecture with provider ports
  status: accepted
  context: AgenticSidebar needs native macOS windowing and menu-bar behavior while supporting more than one agent backend without binding the chat UI to provider-specific APIs.
  drivers:
    - Preserve native SwiftUI and AppKit behavior.
    - Keep provider-specific protocols outside presentation code.
    - Make session and provider behavior independently testable.
    - Avoid an unnecessary Node sidecar for the first milestone.
  considered_option_ids:
    - OPT-001
    - OPT-002
    - OPT-003
  selected_option_id: OPT-001
  decision: Adopt a native Swift modular monolith. Presentation and application state depend on provider-facing protocols; concrete OpenAI and OpenCode adapters implement those protocols at the boundary.
  positive_consequences:
    - Native macOS lifecycle and UI remain first-class.
    - Provider implementations can evolve independently of the chat surface.
    - The first milestone has one application process and no JavaScript runtime dependency.
  negative_consequences:
    - AppKit interop remains necessary for selected desktop behaviors.
    - Provider adapter contracts must be maintained as external APIs evolve.
  assumptions:
    - OpenCode's documented HTTP server remains sufficient for programmatic session integration.
    - Direct OpenAI requests can be implemented with Foundation networking without requiring a third-party runtime.
  validation_criteria:
    - Presentation modules compile without importing provider-specific transport implementations.
    - Both provider adapters satisfy the same session-facing protocol tests.
    - No Node runtime is required to launch the first milestone.
  supersedes: []
---

# ADR-001: Use a native modular macOS architecture with provider ports

Accepted option OPT-001 is a native Swift modular monolith with provider-facing ports and concrete boundary adapters.

- OPT-001: Native SwiftUI/AppKit modular monolith with provider ports.
- OPT-002: Native shell plus Node sidecar using the OpenCode JavaScript SDK.
- OPT-003: Thin native client requiring a separately user-managed OpenCode service.

The selected option keeps native behavior central while avoiding a second runtime. The principal cost is maintaining clear Swift module and protocol boundaries as provider capabilities change.

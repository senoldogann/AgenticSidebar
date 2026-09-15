---
schema_version: 1.0.0
revision: 1
decision:
  id: ADR-002
  title: Support direct OpenAI and managed-local OpenCode backends
  status: accepted
  context: The user must be able to choose OpenAI or OpenCode dynamically, then choose a model and a valid effort or variant level for the selected backend.
  drivers:
    - Preserve direct OpenAI access without forcing OpenCode into every request path.
    - Reuse OpenCode's existing provider, session, auth, and event APIs instead of reimplementing its agent runtime.
    - Populate provider/model/effort choices from real backend capabilities.
  considered_option_ids:
    - OPT-004
    - OPT-005
    - OPT-006
  selected_option_id: OPT-004
  decision: Implement a direct OpenAI Responses adapter and an OpenCode HTTP adapter. The application may manage a localhost OpenCode server lifecycle and protects it with local-only binding plus server credentials. Model and effort choices are capability-driven per backend.
  positive_consequences:
    - Users can choose direct OpenAI or the richer OpenCode agent runtime per session.
    - OpenCode owns its provider-specific agent execution behavior.
    - The UI can expose only valid model-specific effort or variant choices.
  negative_consequences:
    - Two transport/state models must be normalized behind one application-facing interface.
    - OpenCode process startup, health, shutdown, and event-stream recovery become application responsibilities when managed locally.
  assumptions:
    - OpenCode is installed or installability can be diagnosed separately; the app will not silently download executables in the first milestone.
    - OpenCode credentials may be set through its supported auth endpoint and are thereafter owned by OpenCode storage.
  validation_criteria:
    - Provider and model lists are loaded from each backend rather than embedded as a fixed UI list.
    - Unsupported effort or variant values cannot be selected for the active model.
    - OpenCode is contacted only through loopback in the managed-local mode.
    - Direct OpenAI secrets are retrieved from Keychain at request time and never persisted in UserDefaults.
  supersedes: []
---

# ADR-002: Support direct OpenAI and managed-local OpenCode backends

Accepted option OPT-004 uses two adapters: direct OpenAI Responses API and a managed-local OpenCode HTTP server.

- OPT-004: Direct OpenAI plus managed-local OpenCode adapter.
- OPT-005: Route every request through OpenCode only.
- OPT-006: Reimplement every provider directly in Swift.

The selected option provides direct OpenAI access while treating OpenCode as an agent runtime, not merely another raw LLM endpoint.

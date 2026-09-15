# First Milestone Integrated Acceptance — 2026-09-15

## Status
**PASS:** every mandatory first-milestone acceptance lane is complete. The application-owned OpenAI credential exists, authenticated model discovery and capability-scoped effort controls passed without model inference, and all previously completed OpenCode/native/background/capture checks remain passing.

## Baseline
- M4 baseline: `7b6007d53af3f69a05808feeabe655f2366eb6e0` (`feat: add managed OpenCode adapter`)
- M5 branch: `feat/m5-integrated-acceptance`
- macOS: 26.6.2
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Installed OpenCode: 1.18.31 at `/opt/homebrew/bin/opencode`

## Automated integrated acceptance
A new deterministic acceptance suite covers provider coexistence and presentation-independent session ownership:

- `testTwoBackendsCoexistAndSubmissionRoutesToSelectedRuntime`
  - loads OpenAI-like and OpenCode-like capabilities together,
  - switches to OpenCode,
  - selects a concrete model and variant,
  - submits through the selected runtime only,
  - verifies normalized assistant completion.
- `testOwnedSessionContinuesWithoutPresentationInteraction`
  - starts an owned provider stream,
  - performs no window/presentation interaction,
  - delivers text + completion,
  - verifies the session reaches `.completed` with the assistant message intact.

Focused result: **2 tests / 0 failures**.

Fresh full-suite result after adding the acceptance tests: **78 tests / 0 failures**.

Fresh product build: `swift build --product AgenticSidebar` → **exit 0**.

Fresh signed launch: `./script/build_and_run.sh --verify` → **exit 0**, AgenticSidebar process present.

## Credential safety and OpenAI acceptance
### Keychain state
Metadata-only lookup was performed with service `com.dogan.AgenticSidebar` and account `openai.api-key`. No secret data was requested or printed.

Result: **OpenAI Keychain item present** (`security find-generic-password` exit 0).

### Settings credential field
The Settings accessibility tree exposes the `OpenAI API key` control as an `AXTextField` whose accessibility description is `secure text field`. This is the host's SwiftUI accessibility representation of the `SecureField`; the credential value was not read.

Settings also states that the saved API key is stored only in macOS Keychain and is never displayed there.

### Static secret-safety scan
No `UserDefaults` access or normal logging calls were found in the credential store, OpenAI adapter, OpenCode adapter, `OpenAICredentialSettings`, or `OpenCodeSettings` paths used for secret handling.

### Live OpenAI host result
The signed application completed authenticated `GET /v1/models` discovery through the direct OpenAI adapter. Host accessibility state showed:

- Provider picker: `OpenAI`
- Non-empty discovered model list: `GPT-6 Astra`, `GPT-5.6 Sol`, `GPT-5.6 Terra`, and `GPT-5.6 Luna`
- Selected reasoning-capable model: `GPT-6 Astra`
- Capability-scoped effort menu: `Default`, `Low`, `Medium`, `High`, `XHigh`, and `Max`
- `High` could be selected and appeared as the active host UI value

For `GPT-6 Astra`, `None` was not offered, matching the verified model-specific capability catalog. `Default` is the host's explicit nil selection and does not encode a reasoning effort in an API request.

No prompt was submitted and no `POST /v1/responses` inference request was made. The credential value was never requested, displayed, logged, or copied outside the application-owned Keychain boundary. No 401, 403, 429, billing, or quota error occurred during model discovery.

## Managed OpenCode acceptance
### Managed process boundary
Settings `Start OpenCode` created an app-owned child with:

```text
/opt/homebrew/bin/opencode serve --hostname 127.0.0.1 --port 54004 --pure
```

Observed:
- child parent was the AgenticSidebar process,
- child CWD was `/Users/dogan/Library/Application Support/AgenticSidebar/OpenCode`,
- listen socket was only `127.0.0.1:54004`,
- unauthenticated `/global/health` returned **401**,
- installed/runtime version was **1.18.31**.

### Dynamic capability UI
After managed startup/capability refresh:
- Provider picker: `OpenCode`
- Model picker contained dynamic backend-discovered models.
- `OpenAI · GPT-5.6` was selected from the real OpenCode model list.
- Variant picker appeared with `Default`; selecting the next real variant changed it to `High`.

This confirms model/variant UI is driven by live OpenCode capability data rather than a presentation hard-code.

### Non-billable session/SSE contract
A disposable OpenCode 1.18.31 loopback server was used without submitting a model prompt:
- session create: **HTTP 200**,
- session ID: present,
- session delete: **HTTP 200**,
- SSE event types observed: `server.connected`, `session.created`, `session.deleted`.

No provider inference/quota was consumed for this probe.

### Explicit stop
Settings `Stop OpenCode` caused the app-owned child to exit and removed OpenCode from the available provider controls after capability refresh. The direct OpenAI provider was verified separately in the later live OpenAI lane above.

## Native/background acceptance
### Dock and menu bar
- Normal Dock icon: **absent**.
- MenuBarExtra enabled: AgenticSidebar exposed two menu bars; the second contained the sidebar toggle surface.
- Disabling the menu-bar setting changed the count from **2 → 1** while both AgenticSidebar and the managed OpenCode child remained alive.
- Restoring the setting changed the count **1 → 2**.

This verifies menu-bar visibility is presentation-only and does not own the backend/session process lifetime.

### Command-B
Real host global toggle:
- before: `ONSCREEN=1`,
- first Command-B: `ONSCREEN=0`,
- second Command-B: `ONSCREEN=1`.

While hidden, both AgenticSidebar and the managed OpenCode child remained alive.

### Command-W and reopen
After Command-W:
- main window closed (`ONSCREEN=0`),
- AgenticSidebar process remained alive,
- managed OpenCode child remained alive.

A subsequent Command-B recreated/reopened the main window (`ONSCREEN=1`).

### Background session ownership
Deterministic integrated test coverage confirms `AgentSessionService` owns active provider work independently of presentation interaction. Real-host window hide/close checks confirm native window lifecycle does not terminate the application or its managed backend process.

## Capture privacy
See `docs/verification/2026-09-15-capture-privacy-matrix.md`.

Key result: a supported macOS window screenshot successfully captured AgenticSidebar on this host. This is expected under the approved best-effort contract and confirms the product must not claim guaranteed screenshot or arbitrary third-party capture exclusion.

Focused capture tests: **2 tests / 0 failures**.

## Final integrated gate
Fresh verification on 2026-09-16:

- `swift test`: **78 tests / 0 failures**
- `swift build --product AgenticSidebar`: **exit 0**
- `./script/build_and_run.sh --verify`: **exit 0**, signed AgenticSidebar process present
- Live OpenAI provider/model/effort host lane: **PASS**, discovery-only and no inference

All mandatory M5 acceptance requirements are complete. The first milestone may be committed locally without claiming any stronger capture-privacy guarantee or performing billable inference.

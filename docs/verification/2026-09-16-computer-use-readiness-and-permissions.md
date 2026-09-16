# Computer Use: readiness, permissions and one-click setup

Date: 2026-09-16
Branch: `feat/chat-ux-streaming-activities-enter`

## The report

> "Make the computer-use system easier to start. Even though it is installed and
> Screen Recording and Accessibility are granted, it still shows as missing."

Two separate problems were behind that sentence.

**The card could not answer the question.** Settings → Computer Use only ever
showed five rows: Node, `dist/cli.js`, "helper exists", the server and the MCP
registration. Nothing about permissions at all. So an integration that was
working perfectly and one whose helper had never been granted Screen Recording
produced the same screen, and the only way to tell them apart was to ask the
agent to run `computer_health` and read the answer out of a transcript.

**One of those rows lied.** `OpenCodeSettings.refreshComputerUseStatus()` read
`self.client`, which is only ever built on the *start* path. Open the settings
window while the server is already running — the app's own launch, or a server
started outside it — and the client was `nil`, so the card reported "Server
stopped" and "Not registered" for a server that was running and an MCP server
that was connected. That is exactly "it still shows as missing".

## What the app can and cannot know

macOS ties Accessibility and Screen Recording to the **signed binary**. This app's
own `AXIsProcessTrusted()`/`CGPreflightScreenCaptureAccess()` answers describe
*this app*, not `ChatGPTSystemComputerRuntime`, so they cannot be used to report
on the helper.

The helper, however, is a stdio NDJSON server — `NDJSONHostServer` with
`protocolVersion: 1`, spawned with no arguments and `stdio` pipes — and its
`health` method returns the four TCC answers
(`accessibilityTrusted`, `screenCaptureAuthorized`, `eventListenAuthorized`,
`eventPostAuthorized`). So the app spawns the helper for one health request and
shuts it down again. That is the same thing the MCP server does at the start of
every turn, and the same thing `scripts/owner-workstation-status.mjs` does, so it
is safe while a helper is already running: each host is a separate process, and
`health` reads nothing and performs no action.

No Node, no JS build and no repository script is involved — the probe works even
when `dist/cli.js` is missing, which is the state the folder is in right after a
clone.

## Implementation

| File | What it adds |
| --- | --- |
| `ComputerUse/ComputerUseReadiness.swift` | The four grants and the Privacy panes that own them, `health` envelope encoding/decoding, `ComputerUseHelperProbe` (spawn + `poll` deadline + single line), helper bundle inspection (bundle identifier, `codesign --display` identity, ad-hoc detection), and one `ComputerUseReadiness` value with a single `state`. |
| `ComputerUse/ComputerUseSetup.swift` | The two fixed setup steps and the `npm` runner. |
| `ComputerUse/ComputerUseStatus.swift` | The card's view model: refresh, deep links, reveal in Finder, copy, run/cancel a step, re-check after a finished install. |
| `Views/Settings/SettingsComputerUseTab.swift` | Rebuilt around a readiness banner, a permissions card with one row per grant and a deep link on the missing ones, a folder picker, and a setup card with Run/Copy buttons and the output tail. |
| `Stores/OpenCodeSettings.swift` | `refreshComputerUseStatus()` now builds the client from `currentConnection()` when the server is already running. |

Design rules that were deliberate:

- **Unknown is never reported as missing.** A helper that does not answer leaves
  the permissions at `nil` → `.permissionsUnknown` → "it is installed but did not
  reply", not four orange rows sending the user to System Settings for nothing.
- **Configuration comes first.** A missing `dist/cli.js` is `.misconfigured`
  regardless of permissions, and the helper is not even asked — proved by a test
  that asserts the probe was never called.
- **The setup buttons cannot become a shell.** `env npm run build` and
  `env npm run setup:computer:macos` are the only two commands, with the folder as
  the only variable, run with the same trimmed environment the OpenCode server
  gets. No shell, no argument from the UI, `npm` resolved from `PATH` so Homebrew
  and `nvm` both work. One at a time, because both write the same `dist`/`.build`;
  Cancel is a `SIGTERM` and is reported as "Cancelled", not as a failure.
- **Ad-hoc signatures are called out.** They are the one case where re-installing
  the helper silently costs the user their two permission switches, so the card
  says so instead of letting a rebuild look like a macOS bug.
- **The probe's own cost is stated** in the Safety card: one health question, no
  action, no screen content.

## Verification

- `swift build -Xswiftc -warnings-as-errors`: clean.
- `swift test -Xswiftc -warnings-as-errors`: **454 tests, 2 skipped, 0 failures.**
  The new file contributes 27 tests across the health envelope, the permission
  mapping, readiness derivation and the status model (including "the helper is not
  probed when it is not installed", "a second step is refused while one runs" and
  "a successful setup re-checks the helper"), plus three regression tests for the
  stale-client bug.
- **The protocol was verified against the real installed helper**, which is the
  point of the opt-in test:

  ```
  $ AGENTIC_SIDEBAR_LIVE_COMPUTER_USE=1 swift test --filter testTheProbeSpeaksTheInstalledHelpersProtocol
  Test Case '...testTheProbeSpeaksTheInstalledHelpersProtocol' passed (0.218 seconds)
  live helper permissions: ComputerUsePermissions(accessibilityTrusted: true,
    screenCaptureAuthorized: true, eventListenAuthorized: true, eventPostAuthorized: true)
  ```

  It is skipped unless `AGENTIC_SIDEBAR_LIVE_COMPUTER_USE=1`, so CI never spawns
  anything and a machine without the helper is not a failure.
- Independent cross-check with the repository's own diagnostic
  (`node scripts/owner-workstation-status.mjs`): `ready: true`, the same four
  grants true, and `tccIdentityStable: true` — the app and the repository agree.

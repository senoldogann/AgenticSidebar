# Screen Recording was reported missing because it belongs to the app, not the helper

Date: 2026-09-16
Branch: feat/chat-ux-streaming-activities-enter

## The report

Settings → Computer Use said **Screen Recording: Missing**, while System Settings
→ Screen Recording listed **ChatGPTSystemComputerRuntime** switched **on**.
Granting it again changed nothing. The card looked broken; it was not.

## What was actually happening

`tccd` answers `kTCCServiceScreenCapture` for the **responsible process** — the
one that launched the helper — and never reads the helper's own row in the
System Settings list. From `/usr/bin/log show --predicate 'subsystem ==
"com.apple.TCC"'`:

```
16:03:50  kTCCServiceScreenCapture, preflight=yes
          from Sub:{com.dogan.AgenticSidebar} Resp:{com.dogan.AgenticSidebar}
          ReqResult(Auth Right: Unknown (None), promptType: 1, DB Action:None)

16:03:57  kTCCServiceScreenCapture, preflight=yes
          from Sub:{com.freebuff.desktop} Resp:{com.freebuff.desktop}
          ReqResult(Auth Right: Allowed (System Set), promptType: 1, DB Action:None)
```

Same binary, same request, two different answers — because the first tree was
launched by AgenticSidebar (no grant) and the second by the terminal host that
does hold one. And the app's own log agrees, per grant:

```
AgenticSidebar[9810] Computer Use: the helper is missing macOS grants: screenRecording
```

Only `screenRecording`. Accessibility, Input Monitoring and posting events came
back `true` from inside the app's tree, which is the proof that those three are
the helper's own rows and that this one is not.

## Consequence for the previous verification

`script/verify-computer-use.mjs` and the opt-in
`AGENTIC_SIDEBAR_LIVE_COMPUTER_USE=1` test both spawn the helper from a shell and
report `screenRecording=true` there. That reading belongs to whatever launched
the script. A green run in the terminal could therefore coexist with a correct
"Missing" inside the app — which is exactly what happened, and it is why the
earlier "100% verified" claim was wrong about this one grant. Both now say so in
the code, and the script's screenshot step demands a real frame
(`bytes > 10_000` and non-zero dimensions) instead of "some bytes came back".

## The fix

- `ComputerUsePermission.subject` names the owner of each grant: `.app` for
  Screen Recording, `.helper` for the other three.
- `ComputerUseAppPermissionReading` reads this app's own preflights in-process
  (no process spawned, nothing prompted) and exposes
  `requestScreenRecording()`, which calls `CGRequestScreenCaptureAccess()` off
  the main actor. That call is the only way an app gets listed in the pane, so it
  is what turns a scavenger hunt into one button.
- `ComputerUseReadiness.isGranted(_:)` and `missingPermissions` read each grant
  from the process macOS asks for it. `missingPermissions` still returns nothing
  while the helper could not be asked: an unknown answer is not a missing grant.
- The card says which process owes each grant, warns that a switched-on
  **ChatGPTSystemComputerRuntime** row does not cover Screen Recording, and notes
  that macOS caches this decision for the life of the process, so a switch that
  is already on may need a quit and reopen.
- `computerUseStatus.refresh` now reads the app's own grant on every refresh, so
  the card cannot disagree with tccd.

## Tests

`Tests/AgenticSidebarTests/ComputerUseReadinessTests.swift`

- `testScreenRecordingIsTheGrantEnforcedOnTheApp` — the subject mapping.
- `testScreenRecordingComesFromTheAppAndTheRestFromTheHelper` — a helper saying
  `true` for Screen Recording does not make a ready setup, and one saying `false`
  does not break one.
- `testAMissingAppGrantIsReportedEvenWhenTheHelperSaysTrue` — the production
  reading above, pinned as a test.
- `testGrantingScreenRecordingAsksMacOSAndReadsTheAnswerBack` — the request is
  made once and the new answer is read back without a manual re-check.
- `testASecondGrantPressWhileMacOSIsAskingIsIgnored`.
- `FakeAppPermissionReader` is now injected by every status test: calling the real
  preflights would make the suite's outcome depend on whoever launched the test
  runner, which is the confusion these tests exist to remove.

`swift build` / `swift test` with `-warnings-as-errors`: **465 tests, 2 skipped
(opt-in), 0 failures**.

## What the user still has to do

The app cannot grant itself Screen Recording. Open the card and press **Grant
Screen Recording…**: macOS lists **AgenticSidebar** in the pane, and switching it
on gives the whole tree — helper included — the grant it needs. If the row is
already on and still reads as missing, quit and reopen the app: macOS caches this
decision per process.

The helper's own Screen Recording row can stay on or be removed; either way it is
not what decides.

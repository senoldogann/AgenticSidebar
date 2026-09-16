# Composer approval control, settings deep link, shortcut regression — 2026-09-16

## What changed

| Area | Change | Evidence |
| --- | --- | --- |
| Composer | The provider badge is gone; the approval level takes its place in the control row — icon, a one-word name (`Ask` / `Approve` / `Full access`) and the pending-prompt count. The explanation is not repeated here: `summary`/`detail` stay in tooltips and in Settings | host run, `ToolApprovalCompactNameTests` |
| Composer copy | The level is a menu of short names only, so the row stays a control row rather than a paragraph; `compactName` exists for exactly that context | `ToolApprovalCompactNameTests` (length and no em-dash summary) |
| More info | `More info` beside the level opens Settings → AI & Models **and scrolls to the tool approvals card** (`SettingsNavigation` + `SettingsAnchor.toolApprovals`). A repeat press scrolls again, because the request carries a sequence number | `SettingsNavigationTests` (3 tests) |
| One control, one place | The window-toolbar level menu was removed: two controls for the same decision read as two decisions, and the composer is where the input being affected is | — |
| Approval card | The in-conversation card's level menu also shows short names, with the summary in its tooltip | — |
| Shortcut regression | **Fixed.** `applicationDidFinishLaunching` registered the built-in default *after* the window had registered the stored choice, so the chosen chord was unregistered and replaced. The launch path now registers `launchShortcut` — the stored choice — and never the built-in default | `LaunchShortcutTests` (2 tests) |
| Shortcut diagnostics | The registration log line now prints the modifiers as well as the key code. ⌘B and ⇧⌘B were indistinguishable in it, which is why a clobbered preference produced no signal at all | host run (below) |

## Why ⌘B stopped hiding/showing the window

Two registrations happen at launch: `RootChatView.onAppear` applies the stored
preference, and `applicationDidFinishLaunching` applied `GlobalShortcutSpec.default`.
They were the same chord until the default changed to ⇧⌘B (so that a fresh install
does not take ⌘B — "bold" in essentially every text field — away from every app),
and only then did the second registration start replacing the user's own choice.

Runtime evidence, before the fix (`modifiers 768` = ⇧⌘B, registered last):

```
14:17:30.363  Registered global shortcut with key code 11
14:17:30.380  Registered global shortcut with key code 11
14:17:30.380  Application launched with accessory activation policy
```

After the fix, with the stored choice `commandB` (`modifiers 256` = ⌘B):

```
14:22:42.109  Registered global shortcut with key code 11 and modifiers 256
14:22:42.126  Registered global shortcut with key code 11 and modifiers 256
```

Both registrations now agree, because both ask the settings store. The ordering of
the two no longer matters, which is the property the old code lacked.

## Verification

- `swift build` and `swift test` with `-Xswiftc -warnings-as-errors`: **393 tests,
  1 skipped (keychain, opt-in), 0 failures**.
- Host run: app launched, OpenCode child listening on authenticated loopback, no
  errors in the unified log, config and audit file written into the app's own
  directory.

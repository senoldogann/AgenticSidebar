# Following up a pasted review: three P2s and eight P3s, item by item

Date: 2026-09-17
Branch: `feat/chat-ux-streaming-activities-enter`
Source list: the review report pasted into the conversation (three P2 findings,
eight P3 bullets). Findings are tracked as `CR-ITEM-6.1` … `CR-ITEM-6.14` in
`TODO_code-reviewer.md`.

## Method

Every item was checked against the working tree *before* any code changed. Nine
of the eleven listed items were already fixed on disk — the file contents, not
the report, decide. The four re-checked by reading:

| Item | Claim | What the tree says |
| --- | --- | --- |
| P2 thumbnail cache | cache key is the URL alone (30-34, 65-69) | `cacheKey(for:maxPixelSize:)` is `"<path>#<Int(maxPixelSize)>"`; 96/520/1800 px cannot collide |
| P2 inspector read | `String(contentsOf:)` on the else branch | `readTextPrefix` uses `FileHandle.read(upToCount: 1 MB)` + 100k-character truncation; no `String(contentsOf:)` remains |
| P2 stealth wording | claims a guarantee | `CapturePrivacyCapabilities.externalCaptureExclusionApplied` + a limitation string naming `sharingType = .none` and its limits |
| P3 drafts | corrupt file silently reset | `ComposerDraftStore.moveAside()` writes `drafts.corrupt.json` before the next save |
| P3 README | says lazy, code eager | both are `LazyVStack` (README line 103) |
| P3 dead code | `onImageTap` unreachable | no `onImageTap` / `previewImagePath` / `ImagePreviewModal` anywhere in `Sources` |
| P3 `approveSafe` | exact match asks more | intentional, pinned by `ToolApprovalPolicyTests` |
| P3 spill files | new persistence surface | `maximumStoredFiles = 50`, pruned on write |

## Fixed in this round

### The stealth rule: four copies, and none of them saw a window born later

`grep -rn "sharingType" Sources` found the same loop in `CapturePrivacyController`,
`MainWindowController`, `WindowSharingObservationView` (inside
`WindowLifecycleBridge`) and `SettingsWindowController`. All of them applied the
setting to the window in front of them plus `window.childWindows` **at that
moment**. A sheet or panel that appears afterwards gets its own `sharingType`
default and was therefore left out of Stealth Mode — the app's own
`WindowSharingConfigurator` in the MCP server sheet is the symptom: a per-site
workaround for a rule that belongs in one place.

`CapturePrivacyController` now owns it:

- it remembers the tracked window and the current preference and applies both
  through one recursive `applySharingType`,
- it observes `NSWindow.didBecomeKeyNotification`,
  `didBecomeMainNotification` and `didChangeOcclusionStateNotification`, so a
  window is set in the same turn AppKit presents it (`queue: nil` runs the block
  synchronously on the posting thread),
- `NSWindow.didOrderOnScreenNotification` does not exist — checked in the SDK
  header rather than assumed; `didChangeOcclusionState` is what fires when a
  window becomes visible,
- observer tokens live in a small box whose `deinit` removes them, because a
  nonisolated `deinit` may not read main-actor state (`appearanceObservers`
  was a hard error under Swift 6),
- adoption waits for the preference to be read at least once
  (`hasReadPreference`): an app that has not read the setting yet must not behave
  as if it had, so a window that appears before the settings store is consulted
  is left to its own registration path.

Tests (`CapturePrivacyControllerTests`):

```
testWindowAppearingLaterIsAdoptedIntoStealthMode
  parent configured with stealth on → .none
  child added to the parent        → .readOnly   (no inheritance)
  didBecomeKey posted for the child→ .none       (the fix)
  stealth switched off             → .readOnly
testWindowAppearingLaterFollowsTheDisabledSetting
  panel forced to .none, setting off → didChangeOcclusionState → .readOnly
testNoWindowIsTouchedBeforeThePreferenceIsRead
  adopt() on a fresh controller        → .readOnly   (unchanged)
```

### A nested hover region clobbered its neighbour's pointing hand

`onHover` fires on change only. When two regions overlap, the inner one leaving
set `NSCursor.arrow` while the outer one was still hovered, and the outer never
re-asserted its cursor. All five modifier variants in `ClickableHoverModifier`
now share `HoverCursorDepth`: entering sets the hand only at depth 1, leaving
restores the arrow only when the last nested region is gone.

`HoverCursorDepthTests` tests the decision, not `NSCursor`, so the result cannot
depend on the machine's cursor state:

```
testNestedRegionsKeepThePointingHandUntilTheLastOneLeaves   (4 asserts)
testRepeatedEnterForTheSameRegionDoesNotPileUp              (6 asserts)
testUnbalancedExitCannotStrandTheCursorOnTheArrow
```

### The inspector: 1 MB read per redraw, and an unbounded image fallback

`loadTextContent()` was called from `body`, so every re-render re-read and
re-decoded the file prefix and re-split it into 100k-character lines — hover,
theme switch, resize, all of it on the main thread. It is now a
`nonisolated static readTextPrefix(of:)` executed on `Task.detached` behind
`.task(id: url)`, rendered from a `TextPreviewState` (loading / text /
unreadable). The `NSImage(contentsOf:)` fallback for formats `CGImageSource`
cannot shrink (SVG) is gated at 24 MB; previously it loaded the original at full
resolution without a bound.

`FileInspectorTextPreviewTests` (writes real files into a temp directory):

```
testHugeFileIsReadOnlyUpToTheBoundedPrefix   ~3 MB file → truncated, < 1/3 of it read
testSmallTextFileIsReturnedWhole
testBinaryFileIsReportedAsUnreadable
testMissingFileIsReportedAsUnreadable
```

### Restored history could forge the block markers

The preamble that carries a transcript across a backend restart is delimited by
`[Conversation history restored…]` / `[End of restored history.]`. A message
containing the closing marker produced a second one, and everything after it
reads like a fresh turn. The markers are constants now and every restored line
is sanitized to `[…]`; the block always has exactly one opening and one closing
marker, and no content is dropped.

## Commands and output

```text
$ swift build -Xswiftc -warnings-as-errors      (no diagnostics)
$ swift test  -Xswiftc -warnings-as-errors
Executed 563 tests, with 2 tests skipped and 0 failures (0 unexpected)

$ ./script/build_and_run.sh
Build of product 'AgenticSidebar' complete! (102.30s)
Signing AgenticSidebar with Apple Development identity: Apple Development: SENOL DOGAN (NTN6W8D2S6)
Installing AgenticSidebar to /Applications...
Installed AgenticSidebar.app to /Applications successfully.
```

## The window server's own answer

`NSWindow.sharingType` is the app's own belief; `kCGWindowSharingState` in
`CGWindowListCopyWindowInfo` is what macOS sees. `script/verify-stealth-windows.swift`
reads the second:

```text
$ defaults read com.dogan.AgenticSidebar settings.stealthModeEnabled
0
$ swift script/verify-stealth-windows.swift --expected 1
sharing=1 (read-only)  Merhaba, proje genelinde derinlemesine bir code-review basla…
PASS  1 window(s) of AgenticSidebar match the expected sharing state
```

Stealth Mode is **off** on this machine, so `read-only` is the correct state and
the probe asserts it. `--expected 0` is the assertion to run after turning the
toggle on; the ON path additionally has the two adoption tests above, but the
excluded state itself has not been observed on this host in this round
(`CR-ITEM-6.14`).

## Leaving the machine as it should be

- one app process (`63468`), one managed server (`63471`), one lease written:
  `~/Library/Application Support/AgenticSidebar/OpenCode/servers/63471.json`,
- the two other `opencode serve` processes (`10904`, `18276`, both `PPID 1`,
  different argument shapes) are the user's own and were not touched,
- nothing was committed; 84 changed/added files sit in the working tree.

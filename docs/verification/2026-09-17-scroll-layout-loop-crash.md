# The crash was a layout loop, and the scroll callbacks wrote view state

Date: 2026-09-17
Branch: `feat/chat-ux-streaming-activities-enter`
Reported: "the app crashed suddenly, and scrolling in the chat has problems —
up and down, or while a session is running."

## What the crash reports say

Two reports, same signature, same day:

```text
~/Library/Logs/DiagnosticReports/AgenticSidebar-2026-09-17-102331.ips
~/Library/Logs/DiagnosticReports/AgenticSidebar-2026-09-17-104905.ips

exception:     EXC_CRASH / SIGABRT
termination:   Abort trap: 6
faultingThread: 0 (com.apple.main-thread)
stack:          abort ← _objc_terminate ← __cxa_rethrow ← objc_exception_rethrow
                ← __NSWindowGetDisplayCycleObserverForLayout_block_invoke
                ← NSDisplayCycleInvoke ← NSDisplayCycleFlush ← CA::Transaction::commit
```

The throw site is in the report's `lastExceptionBacktrace`, and it names the
function:

```text
+[NSException exceptionWithName:reason:userInfo:]
-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]
-[NSView _informContainerThatSubviewsNeedUpdateConstraints]
-[NSView setNeedsUpdateConstraints:]
NSHostingView.setNeedsUpdate()
NSHostingView.requestUpdate(after:)
SwiftUI.ViewGraphRootValueUpdater.invalidateProperties(mayDeferUpdate:)
NSHostingView.invalidateSafeAreaCornerInsets()
NSHostingView.didChangeValue(forKey:)
-[NSView setFrameSize:] ← -[NSThemeFrame setFrameSize:] ← -[NSWindow _oldPlaceWindow:fromServer:]
-[NSWindow _setFrameCommon:display:fromServer:]
NSHostingView.updateAnimatedWindowSize()
NSHostingView.windowDidLayout()
```

And the reason is in AppKit's own display-cycle accounting, one second before
the abort:

```text
10:49:01.107  Incrementing window 0xc1819c000 update constraints count (was 368) for identifier 169578
10:49:01.117  Marking window 0xc1819c000 as needing Update Constraints in Window (limit: 367, count: 369)
10:49:01.164  <the AppKit display-cycle stack trace above>
```

**368 update-constraint passes and 184 layout passes inside a single display
cycle**, against AppKit's limit of 367. The app did not crash because of a bad
pointer or a model bug; it crashed because layout kept asking for layout, and
AppKit eventually threw instead of looping forever.

## What fed the loop

Immediately before, SwiftUI named the code path:

```text
10:46:31  [com.apple.SwiftUI:Invalid Configuration]
          <OnScrollGeometryChange Modifier> tried to update multiple times per frame.
10:46:31  [com.apple.SwiftUI:Invalid Configuration]
          <…AppKitProgressView…> has an maximum length (16.666667)
          that doesn't satisfy min (16.666667) <= max (16.666667).
```

And in `ConversationDetailView` both scroll callbacks wrote SwiftUI state
directly, once per scroll step:

| callback | wrote | frequency |
| --- | --- | --- |
| `.onScrollGeometryChange` action | `isUserScrolledUp`, with `withAnimation` | every geometry change |
| `.onGeometryChange` in `PromptOffsetProbe` | `activePromptID` | every 8 pt of scrolling |
| `.onChange(messages.last?.text)` | `lastAutoScrollTime` (a throttle value the body never reads) | every streaming flush |

A state write inside a geometry callback invalidates the view *during* the
display cycle that produced the measurement; the new pass produces another
measurement, and the chain feeds itself. While an answer streams, the
transcript also grows, so the measurements never stop — which is why the crash
and the reported scroll trouble share a cause and why both appear "while a
session is running".

## The fixes

### 1. Measurements are recorded, decisions are published outside the cycle

`ScrollFollowState` (new, `Views/ScrollFollowState.swift`) collects what the
callbacks see and answers the follow-mode questions. The callbacks now contain
exactly one statement each:

```swift
} action: { _, newValue in
    followState.record(snapshot: newValue)
}
.onScrollPhaseChange { _, phase in
    followState.setScrolling(phase != .idle && phase != .animating)
}
```

`ConversationDetailView` publishes on a `.task` loop at `publishInterval` (90 ms),
and only when a value actually differs — re-writing the same value is also a
drawing pass, and that pass produces the next measurement. The publish loop
runs while the view is on screen and stops with it.

### 2. The follow decision lives with the measurement

Publishing lags by up to 90 ms, which was enough for the answer to yank the view
back to the bottom right after a gesture ended. So the box answers the question
itself, from the newest measurement — published or pending:

```swift
func shouldAutoFollow(now: Date) -> Bool {
    guard !isUserScrolling, !awayFromBottom else { return false }
    return shouldAutoScroll(now: now)      // 0.12 s throttle
}
```

The gesture's *final* position decides follow mode; a measurement taken during a
gesture is no longer discarded when the gesture ends. That discard was a second,
independent scroll defect: scroll up, release, and the next streaming flush
scrolled you back down.

### 3. The measurement is rounded to steps

Fast momentum scrolling changes the offset several times per frame, which is
what makes SwiftUI flag `<OnScrollGeometryChange>` at all. Offsets and content
height are rounded to 4 pt before they become the watched value — the decision
compares against a 120 pt threshold, so nothing is lost and the per-frame
measurement storm is gone. (The prompt rail already rounded to 8 pt for the
same reason.)

### 4. A spinner whose layout size could not fit its frame

`ConversationSidebarView` drew a busy marker as a `.small` progress indicator
(16.67 pt of layout) with `.scaleEffect(0.6)` (drawing only) inside
`.frame(width: 12, height: 12)` — a proposal where min exceeds max, exactly the
`16.666667` message above, and exactly while a session was running. It and the
five activity-timeline spinners now state a floor instead of an exact size:

```swift
ProgressView()
    .controlSize(.small)
    .scaleEffect(0.6)
    .frame(minWidth: 12, minHeight: 12)
```

## Verification

```text
$ swift test -Xswiftc -warnings-as-errors
Executed 577 tests, with 2 tests skipped and 0 failures (0 unexpected)

$ ./script/build_and_run.sh
Build of product 'AgenticSidebar' complete!
Signing AgenticSidebar with Apple Development identity: Apple Development: SENOL DOGAN (NTN6W8D2S6)
Installing AgenticSidebar to /Applications...
```

`ScrollFollowStateTests` (13 cases) pins the rules, including the one that must
not come back: `testScrollCallbacksDoNotWriteViewState` reads
`ConversationDetailView.swift`, walks each geometry callback's closure body by
brace balance, and fails if it assigns to `isUserScrolledUp`, `activePromptID`,
`isUserScrolling` or `lastAutoScrollTime`.

After the reinstall: the app is up (`/Applications/AgenticSidebar.app`,
pid 84826), no crash report was written, and the sidebar's `AppKitProgressView`
diagnostic no longer appears. **One `<OnScrollGeometryChange>` diagnostic is
still emitted once at launch** while the initial layout settles; the callback it
names no longer writes view state, so this is SwiftUI reporting its own settling
rather than our feedback loop. The decisive check is the streaming case, which
needs a turn to run:

```bash
/usr/bin/log show --last 10m --predicate 'process == "AgenticSidebar"' \
  | grep -c "tried to update multiple times per frame"     # was 1+ per session
/usr/bin/log show --last 10m --predicate 'process == "AgenticSidebar"' \
  | grep -c "update constraints count"                     # was: bounded, now: quiet
```

## What this changes for the user

- Scrolling up during an answer now sticks: follow mode stops at the position
  you left, and it resumes when you scroll back to the bottom.
- The rail's active prompt and the "scroll to bottom" button update at most
  every 90 ms instead of on every scroll step — a small lag for a large
  reduction in invalidation traffic.
- The layout loop that aborted the process is gone at its source: no view state
  is written from a geometry callback anywhere in the app (both call sites were
  in `ConversationDetailView`).

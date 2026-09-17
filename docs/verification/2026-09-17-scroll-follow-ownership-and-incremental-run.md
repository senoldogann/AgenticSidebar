# Scroll that stutters while descending — two causes, measured (2026-09-17)

Reported twice: *"yukarıdayken aşağıya doğru indirirken hâlâ takılmalar oluyor;
sanki yukarıdan kaydırmayı biri tutuyor da bırakmak istemiyor gibi, ama iniyor."*

Two independent mechanisms were found. One is in the streaming render path and is
measured below; the other is the follow logic, which decided "at the bottom" far too
generously and could still scroll the view during an un-signalled gesture.

## 1. The streaming flush saturated the main thread (measured)

A flush rewrites the assistant message's text. `MarkdownContentView` re-parses it
(cheap: 0.6–2.9 ms for 4–27k characters) and then `SelectableMarkdownTextView`
rebuilt the **whole run**: `MarkdownTextRunBuilder.attributedString` over every
block, `setAttributedString` into the text storage, and a full `ensureLayout`.

| Answer length | Attributed-string build | Set + full layout |
| --- | --- | --- |
| 4.1k chars | 10.5 ms | 19.9 ms |
| 14.4k chars | 21.7 ms | 14.0 ms |
| 26.8k chars | 40.8 ms | 27.0 ms |

Flushes are scheduled every 16 ms (fast mode) to 40 ms (normal). Work per flush
exceeded the cadence and grew with the answer, so the main thread never idled for
the length of a turn — a drag is then processed only in the gaps, which is exactly
"it moves, but something is holding it".

### The fix

`SelectableMarkdownTextView.apply(blocks:typography:to:coordinator:)` finds the first
block whose text differs, pulls back one block (the block that just lost its "last"
status changes its paragraph spacing), and replaces only that tail in the text
storage. The unchanged prefix keeps its existing attributes **and its existing
layout**.

| Flush # (growing answer) | old | new |
| --- | --- | --- |
| 5 (1.0k chars) | 2.7 ms | 0.6 ms |
| 10 (2.1k) | 6.0 ms | 0.8 ms |
| 20 (4.1k) | 10.3 ms | 0.7 ms |
| 30 (6.2k) | 15.1 ms | 0.8 ms |
| total, 30 flushes | **266.0 ms** | **22.7 ms** |

The new cost is flat: it does not grow with the answer.

Side effect worth having: a selection made in an earlier paragraph now survives the
answer growing below it. `setAttributedString` destroyed it on every flush.

### Proof

`MarkdownRunIncrementalUpdateTests` (7 cases). The equivalence check is against a
**real** text storage written the old way (`setAttributedString` into a scratch
`NSTextView`), not against the raw builder output: `NSTextStorage` applies the
paragraph style to the paragraph separator itself, so the raw output differs at that
one character in *both* paths. Asserted: appending a block rewrites only the tail
(`lastEdit.location > 0`), a middle block rewrites from that block, a typography
change rebuilds everything, an unchanged run is not touched, and the storage is
`isEqual(to:)` the old full write at every step.

## 2. Follow mode decided ownership by the wrong signal

`ScrollFollowState` recorded a position only while SwiftUI reported a scroll phase.
Some input devices never report one, in which case `awayFromBottom` never updated and
follow mode stayed armed while the user scrolled — the app kept pulling the view
toward the bottom during their gesture.

Two changes:

- **Ownership by a falling offset.** Content growing below never lowers
  `contentOffset.y`, so a fall of ≥ 8 pt is unambiguous evidence that the user moved
  up, whatever device they used, and it hands them the position. Ownership ends when
  a measurement says they are back at the bottom (or a new turn starts).
- **"At the bottom" is 40 pt, not 120 pt.** At 120 pt a reader a few lines up was
  still inside the band, so the streaming answer kept dragging them back down.

`ScrollFollowStateTests` covers the new rules: ownership without any phase report,
ownership surviving a descent that has not reached the bottom, returning into the
band handing follow back, and a 4 pt jitter not granting ownership.

## 3. A stuck instance of the previous build (found, not explained)

The previous build's process (pid 84826, launched 13:22) was still alive, and it was
not merely idle:

- `ps`: state `R`, **99% CPU**, after 31 minutes of uptime.
- It **ignored SIGTERM** — the app's own shutdown runs on the main queue, which never
  got control, so the dispatch source never fired.
- `sample` (4 s, 2579 main-thread samples, `docs`-level evidence in
  `/tmp/app84826.txt`): a SwiftUI update loop. `NSHostingView.beginTransaction` 2141,
  `AG::Graph::UpdateStack::update` 834+447, `AG::Subgraph::update` 1336+290,
  `NSHostingView.didRequestHoverUpdate()` 423, `-[NSClipView hitTest:]` 540,
  `propagate_dirty` 477. No drawing frames at all (no `CABackedStore`/`CGContext`/
  `setNeedsDisplay`) and our own views appear only in single-digit samples — so this
  was *not* rendering, not our view bodies, and not the markdown path.

What it is: a self-feeding graph-update loop driven by hover re-evaluation and hit
testing inside the transcript's clip view. What started it is not yet proven, and the
fresh build has not been observed entering it: it sits at **0.1% CPU**. Recorded as
`CR-ITEM-8.1` rather than guessed at.

The stuck process was killed (`SIGKILL`, since it could not run its own shutdown) and
its orphaned OpenCode server (port 50096) was terminated with it. One app and one
server remain: pid 86947 / port 50206. The user's own two servers were untouched.

## Verification

- `swift build` and `swift test -Xswiftc -warnings-as-errors`: **588 tests, 2 skipped,
  0 failures**.
- Rebuilt, signed (`Apple Development: SENOL DOGAN`), installed to `/Applications`,
  launched. One instance, one server, no new crash report.
- Not verified by me: the *feel* of the descent. The two mechanisms above are
  measured; whether they were the whole of what the user felt is theirs to say.

## Commands

```bash
# the measurement this round rests on (temporary scratch test, removed afterwards)
swift test --filter ScrollFlushCostScratch

# the rules
swift test --filter "MarkdownRunIncrementalUpdateTests|ScrollFollowStateTests"

# full gate
swift test -Xswiftc -warnings-as-errors

# look for a stuck instance again
ps -o pid,stat,%cpu,etime -p "$(pgrep -x AgenticSidebar | head -1)"
sample "$(pgrep -x AgenticSidebar | head -1)" 4 -mayDie -file /tmp/app.txt
```

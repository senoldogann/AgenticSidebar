# Message actions, queue editing, and selecting an answer — 2026-09-16

Five requests, in the order they were made. Each one names what was wrong, what
changed, and how it is verified.

## 1. Copy and "write again" on my own messages

**Requested:** after the session is stopped, my messages should have a re-send
icon that puts the message back in the input, and a copy icon.

**What was there:** assistant messages had a copy button; user messages had no
actions at all.

**Change:** `ChatMessageRow` builds one copy control for both roles (the old
assistant copy button hand-rolled its own hover, so the two would have drifted)
and adds **Write again** to user messages. The re-send control hands the message
to `ComposerDraftCenter`, which the composer consumes: the text lands in the
input to be edited, it is *appended* to an unsent draft rather than replacing it
(`ComposerDraftPlacement.merged`), and attachments are restored only if the file
is still on disk. `Write again` appears only when the turn is over — sending the
same text mid-turn would queue a duplicate of something the user has not seen
answered yet.

**Why the indirection:** the draft lives inside `ComposerView` and the transcript
is a sibling view, so a shared center means neither has to know the other. The
restore request names its session, and is consumed only when it has been applied,
so a request for another conversation cannot type into the wrong field.

**Verified by:** `ComposerDraftCenterTests` (handover is once-only, each click is
its own event, the session is named) and `ComposerDraftPlacementTests` (append,
not replace).

## 2. A queued message can be rewritten and reordered

**Requested:** edit a queued message from its icon and send it again; when
several are queued, drag them to change their order.

**Change:** `AgentSession.updateQueuedPrompt(_:text:)` rewrites the text in place
and refuses empty text, keeping the speed mode, agent mode and attachments the
prompt was written with. `AgentSession.moveQueuedPrompt(_:to:)` moves a prompt to
a position, clamping the destination so that dropping past the last row means
"at the end". The strip became its own view (`QueuedPromptsStrip`) with an inline
editor (return saves, escape cancels, a refused save keeps the row open), a grip
handle that is the only draggable part — making the whole row draggable would
fight the text selection inside it — and a hover state per row.

**Verified by:** four new tests in `AgentModeAndPromptQueueTests`: an edit does
not move the message, an empty edit is refused, clamping and no-op moves behave,
and a reordered queue actually *runs* in the new order (`first, third, second`).

## 3. Hover and cursor across the interface

**Requested:** every clickable thing — the composer especially — should get a
theme-consistent hover highlight, and the cursor should become a hand.

**Change:** an audit of every `Button`/`onTapGesture` in `Sources/` (a script over
the tree, re-run until no site was left without a hover or cursor modifier) found
the gaps: the send and stop buttons, the scroll-to-bottom button, activity
timeline rows, session rows in the sidebar, the image attachments, the image
preview sheet's controls, and most of the Settings buttons.

Two modifiers were added because the existing three could not express these
cases: `interactiveHoverOutline` for a control that paints its own opaque
background (a plate drawn *behind* an opaque circle is invisible — which is why
send and stop showed no hover at all), and `interactiveHoverHalo` for controls
that sit on the image preview's black backdrop, where a label-coloured highlight
disappears. Everything uses `Color.primary.opacity(…)`, so the highlight follows
the appearance instead of being tinted to one theme.

## 4. Selecting everything the agent wrote

**Requested:** select all the agent's text with the mouse, dragging from top to
bottom if necessary.

**What was there:** `.textSelection(.enabled)` was already on the transcript, but
markdown renders one `Text` per paragraph, heading and list item, and a selection
cannot cross text views — a drag stopped at the first paragraph break. This is a
SwiftUI limitation, not a missing modifier
([robb.is, July 2026](https://robb.is/writing/text-selection-in-swiftui/):
"SwiftUI's new text selection does not actually support selecting across Text
views").

**Change:** consecutive prose blocks of a message are now grouped into one run and
laid out in a single AppKit text view (`SelectableMarkdownTextView`, backed by
`MarkdownTextRunBuilder`). One text view per run is what makes a whole reply
selectable in one gesture. The run ends at a code block, table, chart or plan
document — those keep their own views and affordances — so a reply is usually one
or two runs instead of one per paragraph.

Details that keep it equivalent to the old rendering: `InlinePresentationIntent`
means nothing to AppKit, so emphasis and code spans are read off the runs and
turned into fonts and a background; paragraph spacing reproduces the stack's gaps
(including *no* trailing gap on the last paragraph, which would otherwise double
the gap before a code block); the token that decides whether to rebuild compares
both the text and the typography, since block ids alone would miss a streaming
paragraph growing.

One AppKit behaviour had to be restored by hand: without it, the wheel over an
answer would be swallowed by a text view that has nothing to scroll
(`TranscriptTextView` forwards `scrollWheel` to the next responder).

**Still true:** a single drag cannot span *two messages*, since they are separate
views — that needs the whole transcript in one text view, which would cost the
per-message affordances (copy, timeline, approval bar). Within a message the
selection now runs from the first paragraph to the last.

**Verified by:** `MarkdownTextRunBuilderTests` — which blocks join a run, that
bold/italic/code survive the conversion (checked through the font traits), the
last paragraph carries no trailing spacing, and the token changes with content and
typography.

## 5. "More info" is gone from the composer

**Requested:** remove it; Settings already explains the levels.

**Change:** the button and the `SettingsWindowController` dependency it needed are
removed. The approval control itself — level name, pending count, menu — stays.
`SettingsNavigation` and its anchor stay: the approval *card* in Settings is still
reachable from the sidebar and from `SettingsAITab`'s own links.

## Checks

```
swift build --product AgenticSidebar -Xswiftc -warnings-as-errors   # clean
swift test -Xswiftc -warnings-as-errors                            # 409 tests, 1 skipped, 0 failures
```

The one skipped test is `KeychainCredentialStoreTests`, which needs an opt-in
login keychain. Fifteen tests are new (`ComposerDraftCenterTests`,
`ComposerDraftPlacementTests`, `MarkdownTextRunBuilderTests`, and four queue
editing tests).

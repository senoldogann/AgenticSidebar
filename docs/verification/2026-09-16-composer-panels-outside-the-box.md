# The queue and the `/` `@` suggestions are panels, not parts of the composer

Date: 2026-09-16
Branch: `feat/chat-ux-streaming-activities-enter`

## The report

> "The `/` or `@` or queue message is still inside the input. I want these to be
> a separate area outside it — no ties to the composer, above it and outside."

## What was actually wrong

Both surfaces belonged to the composer *box*, which is why they kept reading as
part of the field no matter how they were drawn:

- The suggestion panel was `composerBox.overlay(alignment: .top)` with an
  `alignmentGuide(.top) { $0[.bottom] }`, so its bottom edge sat exactly on the
  box's top edge with a translucent, theme-coloured background. Two touching
  rounded rectangles with the input's own corner behind them read as one control
  — the screenshot showed the composer's control row visible under the panel's
  bottom corner.
- The queued prompts strip was a child *inside* `composerBox`'s `VStack`, sharing
  the box's background, border and corner radius. It was literally inside the
  input.

## The change

`ComposerView.body` is now a `VStack` of siblings:

```
floatingPanel { queuedPromptsStrip }   // when messages are queued
floatingPanel { extensionSuggestions } // when `/` or `@` is active
composerBox
```

- No overlay, no `alignmentGuide`, no shared edge and no `zIndex`: the panels are
  laid out above the input, so nothing of the composer is *underneath* them.
- `floatingPanel` gives both the same chrome — own surface, own border, own
  shadow, 10pt corner radius — and an 8pt gap separates them from the box. The
  panel styling that used to live inside `extensionSuggestions` moved into that
  one helper, so the two panels cannot drift apart.
- `composerBox` kept only what the user is composing into: selected tags,
  attachments and the field with its controls.
- The composer's own position does not move: `ConversationDetailView` puts the
  branch in a `ZStack(alignment: .bottom)` whose transcript is the flexible
  child, so a panel opening takes height from the transcript above, not from the
  field being typed into.

## Verification

- `swift build -Xswiftc -warnings-as-errors`: clean.
- `swift test -Xswiftc -warnings-as-errors`: **454 tests, 2 skipped, 0 failures.**
- App rebuilt, signed and running with the change in place. Visual layout is the
  one thing this repository's tests cannot assert; the structural property they
  would have asserted — the queue strip and the suggestion panel are no longer
  children of the composer box — is now true by construction, since
  `composerBox` no longer references either.

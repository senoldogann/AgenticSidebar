# Activity history and the prompt rail

Date: 2026-09-16
Scope: activity timelines surviving a relaunch, and prompt navigation in the transcript.

## What was wrong

The conversation remembered its messages but not what the agent *did*. Activity
groups lived only in `AgentSessionState`, so every `Edit`, `read` and `bash` row
disappeared the moment the app quit — the transcript came back with answers whose
work was invisible, and there was no way to tell which commands a session had run.

Long conversations had the opposite problem: no way to move around inside them.
The only navigation was "scroll to the bottom", so returning to an earlier prompt
meant dragging the scrollbar and hunting.

## What changed

### The timeline is part of the conversation

- `ProviderActivityID`, `ProviderActivityKind` and `AgentActivityPhase` are
  `Codable`; `AgentActivity` and `AgentTurnActivityGroup` follow.
- `SessionSnapshot` carries `activityGroups` and `SessionArchive.currentVersion`
  is `2`. The key is decoded with `decodeIfPresent`, so an archive written before
  the timeline existed still loads — that case is covered by a test that decodes
  a hand-written version 1 file.
- A finished turn comes back collapsed under its "Thinking" row, which is the
  same shape it has at the end of a live turn. Expanding it shows the recorded
  `+`/`-` diff, the file contents, or the console output.

### A restored turn is closed, not left running

An activity that was `.running` when the process died can never finish, and the
thinking row would otherwise count up from a stale start date forever. Both the
activity and its `completedAt` are closed at the last known instant on restore
(`AgentActivity.normalizedForRestore`).

### The archive stays bounded

Tool results are unbounded — full file reads, terminal scrollback — so the
timeline is what could push `sessions.json` past `maximumArchiveBytes`, and an
oversized archive is refused on load. That refusal would cost *every*
conversation at once, so:

- `maximumActivityOutputLength` (4,000 characters) caps each tool result and
  change preview, with the number of dropped characters written into the text;
- `maximumActivitiesPerSession` (120) keeps the newest activities; older turns
  are dropped whole, and a single turn longer than the whole budget keeps its
  newest steps rather than none;
- groups whose anchor message is no longer in the transcript are dropped;
- `maximumArchiveBytes` rises from 16 MB to 64 MB, which clears the worst case
  the caps above allow (≈24 MB of activities over 50 conversations).

### The prompt rail

`PromptNavigatorRail` draws one bar per prompt in the transcript's left gutter,
vertically centred, in a spindle: the bars grow and drift right toward the middle
of the column, and the bar for the prompt being read is filled with the theme
accent instead of `Color.primary`. Hovering shows the prompt; clicking scrolls it
to the top of the transcript. The rail appears only once a conversation has more
than one prompt.

Which bar is lit comes from `PromptRailSelection`: rows report their position
relative to the top of the viewport through `PromptOffsetProbe` (a
`Navigator`-style geometry probe on user rows only), rounded into 8-point steps so
a scroll gesture does not publish a state change on every frame. The highlighted
prompt is the lowest one still at or above the top of the viewport.

The rail never covers the text: the transcript reserves `PromptRailMetrics.columnWidth`
of leading inset while the rail is shown, and the bar geometry is tested to stay
inside that column including the active and hover bumps.

## Verification

```
swift build --product AgenticSidebar   # clean
swift test                             # 258 tests, 0 failures
```

New coverage:

- `SessionPersistenceTests` — a timeline round-trips through the archive store and
  keeps its anchor message; a running activity is closed on restore; oversized
  output is truncated and marked; a timeline with no message is dropped; a single
  over-budget turn keeps its newest steps; a pre-timeline archive still decodes.
- `PromptNavigatorRailTests` — the single-prompt case sits at the middle, bars grow
  and drift monotonically toward it and are symmetric, no bar leaves its column,
  and the highlight follows the reading position including above and below the
  measured range.

## Limits

- Only the last 120 activities per conversation survive; older turns come back
  without a timeline.
- Tool results are stored as a 4,000-character preview, so a restored diff or
  console output can be shorter than the live one (marked in the text).
- The rail maps the newest 60 prompts of a conversation.
- Visual confirmation of the rail and the collapsed timeline is the user's to
  make; the geometry and selection rules are unit-tested, but the rendering is
  not.

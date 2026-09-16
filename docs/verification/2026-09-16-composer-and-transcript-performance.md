# Composer and transcript performance

2026-09-16

## What was slow, and why

Two complaints: pasting a long document into the composer stalled the app, and
switching between conversations loaded slowly.

Neither was a slow algorithm in the obvious place. Both were **work proportional
to all of the text, done per keystroke and per frame**:

| Where | What it did | Cost |
| --- | --- | --- |
| `ComposerTextEditor.sizeThatFits` | laid out the **whole** draft to compute a height it then capped at 104 pt | text layout of the entire document, on every keystroke and every state change |
| `ComposerView.submissionAvailability` | `trimmingCharacters(in: .whitespacesAndNewlines)` | a full copy of the draft per keystroke |
| `ExtensionTrigger.detected` | scanned the draft **forwards from the start** to find the last whitespace | a walk of the whole draft per keystroke |
| `ConversationDetailView.promptItems` | trimmed and split every prompt in the conversation, inside `body` | the whole transcript's prompt text, ~25 times a second while streaming |
| `activityGroup(after:)` | linear scan of every turn, per rendered row | groups × rows, per frame |
| `MarkdownParseCache` | per-view `@State`: correct while a message stayed put, **empty on every new view instance** | every visible message re-parsed after each conversation switch |
| `ConversationSidebarView.sessionSubtitle` | Foundation relative-date formatting per row, inside `body` | rows × frames while a turn runs |

The third row is what made a paste feel stuck: typing one character after a paste
walked the entire document, twice (trigger scan plus the availability trim), then
laid it all out again.

## What changed

- **`ComposerDraftMetrics`** (new): allocation-free questions about a draft.
  `hasContent` stops at the first non-space character; `measuredPrefix` returns at
  most 2 KB for height measurement, using `utf8.count` (O(1)) so even deciding
  *whether* to truncate does not walk the document.
- **`ComposerTextEditor.sizeThatFits`** measures only that prefix — the editor is
  capped at a few lines, so nothing beyond it can change the answer.
- **`ExtensionTrigger.detected`** scans backwards over a 256-character window and
  stops at the start of the word being typed; a word longer than the window is not
  offered as a trigger rather than being offered with a truncated query.
- **`TranscriptIndex` + `TranscriptIndexCache`** (new): the rail's titles and the
  activity-group lookup are built once per change, with independent keys so
  streaming assistant text — which changes on every frame — rebuilds neither.
- **`MarkdownParseStore`** (new): a bounded, shared parse cache consulted by the
  per-view cache, so returning to a conversation reuses what was already parsed.
  Bounded in entries (256) and characters (1 M): retaining a long session's parsed
  code blocks forever would trade a stall for a leak.
- **`RelativeTimestamp`** (new): the sidebar's relative dates are bucketed to the
  minute and cached, with a bounded LRU.

## Tests

`Tests/AgenticSidebarTests/PerformanceTests.swift` — the properties, not the
timings:

- `ComposerDraftMetricsTests`: whitespace-only drafts, the 2 KB measurement
  prefix, and 50 measurements of a 1 MB draft inside half a second.
- `ExtensionTriggerScanTests`: a trigger after a 700 KB paste is found with the
  right range; 200 scans of a 2 MB draft inside a second (a full scan would not
  be); a word longer than the window is refused; an earlier mention of `@` is not
  mistaken for the word being typed.
- `TranscriptIndexTests`: rail order, the 60-prompt cap, title rules, anchor
  lookup, **25 streaming frames rebuild the rail zero times**, a new prompt
  rebuilds the rail and not the groups, a starting activity rebuilds the groups
  and not the rail.
- `MarkdownParseStoreTests`: a second cache instance (a conversation switch) hits
  the store instead of re-parsing; the per-view cache still answers without
  touching the store; changed text re-parses and keeps both versions; plan
  recognition is part of the key; the store stays within its bound and keeps the
  newest entries.
- `RelativeTimestampTests`: one format per minute, a new minute is a new entry,
  the cache is bounded.

## Honest limits

- The timing assertions are deliberately loose (a second, half a second). They
  catch a return to whole-input work; they are not benchmarks. Measured on this
  machine the 22 bounded-work tests finish in about 30 ms together.
- What is verified is what a test can reach. The felt improvement of a large
  paste and of a conversation switch is a rendering matter, and the numbers above
  are the mechanism, not the proof: the proof is a paste into the composer and a
  switch between two long conversations.
- Assistant text still re-parses as it streams — that is inherent to rendering a
  growing markdown body, and it is now the *only* per-frame cost proportional to
  the text being streamed, not to the whole transcript.

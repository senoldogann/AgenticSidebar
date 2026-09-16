# Deferred work completed — 2026-09-16

Follow-up to `2026-09-16-review-remediation.md`. That pass fixed the high-severity
findings and explicitly postponed four items; this document records closing them.

Scope note: the managed agent's permission model was left untouched in both passes
(`replyPermission(..., reply: "allow")` and the generated `opencode.json` allow-list
are unchanged), and all user-facing copy stays English.

## 1. Stream back-pressure

**Before:** every hop used `AsyncThrowingStream` with `.makeStream()`, which accepts
every element immediately. A long tool-heavy turn could buffer thousands of deltas in
memory while the consumer applied them one at a time.

**Now:** `Support/BoundedChannel.swift` is a bounded single-producer/single-consumer
channel. `send` suspends while the buffer holds `capacity` elements, `receive` releases
one producer slot per consumed element, and both `finish` and `cancel` release every
waiter so a torn-down consumer can never strand a producer.

Wired into all four hops, so pressure propagates from the UI all the way back to the
socket:

| Hop | Capacity |
|---|---|
| `URLSessionOpenAITransport` lines | 256 |
| `OpenAIProviderRuntime` events | 128 |
| `URLSessionOpenCodeTransport` lines | 256 |
| `OpenCodeProviderRuntime` events | 128 |

Back-pressure is bounded, not lossless-free: `URLSession` still buffers what it has
already read from the socket, so the guarantee is "no unbounded *queue* growth in the
app", not "no buffering anywhere".

## 2. Context budget

`AgentCore/TranscriptBudget.swift` trims a request transcript to a character budget
(96 000 ≈ 24 k tokens, four characters per token). Rules:

- whole messages only, from the oldest end;
- the newest message is always kept, even alone, because the user just wrote it;
- the window starts on a user turn when possible;
- `AgentSessionState.notice = .transcriptTrimmed(droppedMessageCount:)` reports the
  trim in the chat view, so the transcript never quietly loses history.

The stored transcript is never trimmed — only the request is.

A provider-side overflow is now distinguishable from a generic bad request on both
backends: `ProviderRuntimeError.contextLimitExceeded` and
`AgentSessionError.contextLimitExceeded` are raised from an OpenAI 400/413 whose body
mentions the context window and from an OpenCode `session.error` carrying a
`ContextOverflowError` envelope. The user sees "This conversation no longer fits the
model's context window. Start a new session to continue."

## 3. OpenCode attachments

Previously deferred because the file-part shape could not be verified. It is verified
now, from the installed `opencode-ai@1.18.31` binary:

```
FilePartInput = { id?, type: "file", mime: String, filename?: String, url: String, source? }
prompt parts = union(TextPartInput | FilePartInput | AgentPartInput | SubtaskPartInput)
CLI attachment builder: url = `data:${mime};base64,${payload}`   (10 MiB local-file cap)
```

`OpenCodeProvider/OpenCodePromptParts.swift` therefore sends real file parts:
readable images, text and PDFs are inlined as `data:` URLs with the same 10 MiB cap the
OpenCode CLI applies. Everything else (archives, binaries, unknown extensions, missing
or oversized files) is referenced by path in the prompt text, which keeps a turn from
failing on one unsupported attachment.

## 4. Multi-session conversations and persistence

- `AgentCore/AgentSession.swift` owns one conversation: transcript, configuration,
  activity timeline and **its own turn task**.
- `AgentCore/AgentSessionService.swift` is now a list of sessions plus capability
  discovery. It keeps the previous public API, forwarding to the active session, so the
  composer, chat view, menu bar and the clipboard/screenshot monitors needed no change
  to their call sites.
- **Background turns keep running** when another session is selected; a busy background
  session no longer blocks input in the active one.
- `AgentCore/SessionArchive.swift` persists the session list as JSON in
  `~/Library/Application Support/<app>/sessions.json`: id, creation date, configuration
  and messages, with ISO-8601 dates and atomic writes. Activity timelines and in-flight
  turns are deliberately not persisted (per-turn UI detail; a turn cannot outlive the
  process). At most 50 sessions are kept; an unreadable file is moved to
  `sessions.corrupt.json` and the app starts clean instead of failing to open.
- Writes are debounced (2 s) for transcript changes and immediate for structural changes
  (create, select, delete), so streaming does not write the archive 25 times a second.
- The sidebar's "New session" / session list / delete actions are real now; both buttons
  previously just closed Settings.

## 5. Inline markdown without localization semantics

`Views/MarkdownInlineText.swift` replaces `Text(LocalizedStringKey(_:))` with an
`AttributedString` built from inline-only markdown. Message content is no longer
treated as a localization key or as a format string, so a stray `.strings` entry or a
`%`/`%@` sequence in a reply can no longer change what the user sees. Malformed
markdown (normal mid-stream, e.g. a half-arrived `**bold`) falls back to literal text
instead of dropping the message.

## Verification

- `swift build --product AgenticSidebar` → clean.
- `swift test` → **183 tests, 0 failures** (136 before this pass).
- New coverage: `BoundedChannelTests` (6), `TranscriptBudgetTests` (8),
  `MultiSessionTests` (11, including background streaming, delete-cancels-turn and
  configuration inheritance),
  `SessionPersistenceTests` (7, including corrupt archive and the 50-session cap),
  `OpenCodePromptPartTests` (7), `MarkdownInlineTextTests` (4), plus context-overflow
  classification added to `ProviderHTTPStatusTests`.

Not verifiable from the command line: rendered appearance of the markdown change and of
the new notice banner. Both are covered by unit tests on the underlying values.

Concurrency note: another agent was editing `MenuBarSessionView`, `ConversationSidebarView`,
`SettingsView` and the typography settings in the same working tree during this pass.
Everything described here was verified against a build that included those edits.

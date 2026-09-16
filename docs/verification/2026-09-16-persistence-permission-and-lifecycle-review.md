# Persistence, Permission and Lifecycle Review — 2026-09-16

## Scope

The second deep review of `feat/chat-ux-streaming-activities-enter`: three high
findings (Y1–Y3), ten medium (O1–O10) and five low (D1–D5). Everything is fixed
except one sub-item of D5, recorded under *Deliberately deferred*.

## Fixed

| ID | Change | Where |
| --- | --- | --- |
| Y1 | Archive writes leave the main actor. `SessionArchiveWriter` is an actor that owns bounding, JSON encoding and the atomic write, so none of it runs on the main thread; overlapping writes serialise, and an unchanged archive is not re-encoded at all | `SessionArchive.swift`, `AgentSessionService.swift` |
| Y2 | A permission request that nobody answers is rejected after `decisionTimeout` (180 s in the app) instead of suspending the turn — and its queue — forever. The timeout is an explicit initializer parameter so it can be driven in tests | `PermissionApprovalCenter.swift`, `AgenticSidebarApp.swift` |
| Y3 | The byte ceiling is enforced where the data is produced. `save` drops the oldest inactive conversations, then the oldest messages of the last one, until the encoded archive fits; if a single message cannot fit, the previous archive is kept rather than replaced with nothing. Every unusable file found on load (oversized, unreadable, undecodable, written by a newer version) is now moved aside instead of being left for the next write to destroy | `SessionArchive.swift` |
| O1 | `managedShutdown` flushes the debounce before the backend stops, so the last two seconds — in practice the finished turn — reach disk | `AgenticSidebarApp.swift`, `AgentSessionService.swift` |
| O2 | `ProviderRuntime.releaseSession` (no-op by default) lets a deleted conversation close its backend session. OpenCode forgets the mapping and issues `DELETE /session/{id}` | `ProviderRuntime.swift`, `OpenCodeProviderRuntime.swift`, `OpenCodeClient.swift`, `AgentSessionService.swift` |
| O3 | Clipboard and screenshot captures hold a bounded FIFO instead of one slot, and hand work over through `send`, so they queue behind a running turn like any other message instead of overwriting each other | `ClipboardMonitorService.swift`, `ScreenshotMonitorService.swift` |
| O4 | Composer text, attachments and extension tags are keyed by session, so a draft written in one conversation is no longer shown in — or sent to — another. Drafts of removed sessions are discarded | `ComposerView.swift` |
| O5 | Markdown parsing is memoised in a per-view cache instead of being computed in `init` and thrown away on every render (and then parsed a second time in `onChange`) | `MarkdownContentView.swift` |
| O6 | The in-memory timeline is bounded like the archived one: activity groups are pruned when a turn ends, and a tool result is capped at 64 000 characters when it is stored. Activity-group and streaming-message lookups check the tail first instead of scanning the whole turn on every event | `AgentSession.swift`, `AgentActivity.swift` |
| O7 | `ProviderHTTPTransport` / `URLSessionHTTPTransport` are the single implementation; the adapter protocols refine it and the adapter response/stream types are aliases of the shared ones, so the third copy of the `URLSession` plus bounded-channel code is gone. `shared()` is renamed `streaming()` — it was never a singleton. Both clients now map HTTP status through `ProviderRuntimeError.forHTTPStatus` | `HTTPTransport.swift`, `OpenAITransport.swift`, `OpenCodeTransport.swift`, `OpenCodeClient.swift`, `OpenAIProviderRuntime.swift` |
| O8 | `response.failed` / `response.incomplete` / `error` keep their cause: rate limit, context overflow, rejected key and backend outage map to distinct errors and the code is logged. A delta event with no text is skipped instead of failing the turn | `OpenAIStreamDecoder.swift` |
| O9 | The default provider and model preference moved out of the session core into `ProviderSelectionPolicy` | `ProviderSelectionPolicy.swift`, `AgentSession.swift` |
| O10 | Deleting a conversation asks for confirmation and names what is about to be lost | `ConversationSidebarView.swift` |
| D1 | The contradictory `supportsSelfCaptureFiltering` flag is gone; no view read it and the limitation text said the opposite | `CapturePrivacyController.swift` |
| D2 | `SettingsStore.isSettingsPresented` is gone; `SettingsWindowController.isWindowOpen` replaced it | `SettingsStore.swift` |
| D3 | A clamped opacity/contrast value now reaches `UserDefaults`. `didSet` no longer returns early after assigning to itself, which left memory and disk disagreeing | `SettingsStore.swift` |
| D4 | Capability discovery runs once at launch, after the OpenCode server starts, instead of once per scene | `AgenticSidebarApp.swift`, `RootChatView.swift` |
| D5 | The prompt queue is capped at 20; beyond that a message is refused rather than silently accumulating behind a stalled turn | `AgentSession.swift` |

## Found and fixed in the follow-up review of this change set

| Defect | Fix |
| --- | --- |
| Pruning the in-memory timeline re-truncated tool results that were already truncated, so every turn shaved the text again and reprinted a wrong "N more characters" count | Group pruning and output bounding are separate operations; only the archive path bounds outputs, and it starts from the live value each time |
| `boundedForMemory` called `String.count` — an O(n) grapheme walk — on every tool update, so a 10 MB result was counted on the main actor on each part update | A constant-time `utf8.count` pre-check short-circuits the common case, and the marker no longer needs the exact dropped count |
| The capture queues allowed 20 pending clipboard/screenshot items, turning one dropped copy into up to 20 automatic paid turns | Capped at 5, with a log when the oldest is dropped |
| The monitors called `send` on every 0.4 s tick even when the session queue was full, producing an error log at 2.5 Hz | `canAcceptPrompt` answers "can this session take a message right now" in one place; the monitors ask before sending and the composer's submit button uses the same answer |
| `response.incomplete` with `max_output_tokens` was reported as a context-window overflow, which told the user to start a new session — advice that does not apply to a truncated answer | It falls through to the provider's own words via `ProviderResponseDiagnostics` instead |
| Moving the model preference into `ProviderSelectionPolicy` silently changed which DeepSeek model wins when several match | The port is faithful again: the first model in the provider's own order that matches any token |

## Also changed while integrating

- A cancelled debounce task no longer clears the handle of the task that
  replaced it, which could otherwise leave two save loops running.
- The "Thought for Ns" measurement moved out of `AgentActivityTimelineView` into
  `ThinkingDurationPresentation`, so it is testable without running a view.

## Verification

- `swift build` → **exit 0**, no warnings
- `swift test` → **354 tests / 0 failures** (294 before this change set; the
  count also includes tests that arrived with the parallel extensions work)

New coverage: the archive writer's whole shrink-until-it-fits loop and its
refusal to write nothing, keeping an oversized archive aside, permission
timeout, remote session release, prompt-queue cap and `canAcceptPrompt`,
clamped-setting persistence, thinking duration text.

## Deliberately deferred

- **Persisting the prompt queue.** D5's second half. Restoring queued prompts
  and running them at launch would send paid requests the user never confirmed;
  restoring them without running them leaves a queue that nothing drains. Which
  of the two is wanted is a product decision, so the cap was fixed and the
  persistence was not.
- **`await stream.cancel()` in `consume`'s early returns.** The review suggested
  it for robustness. It is not safe as written: the cancellation closure aborts
  the *remote* session, which a sibling turn on the same conversation would be
  using. The guards are unreachable today — `cancel()` awaits the turn task
  before any queued turn starts — so they were left alone rather than made
  actively harmful.

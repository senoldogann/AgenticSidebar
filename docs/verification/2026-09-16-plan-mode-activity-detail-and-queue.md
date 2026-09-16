# Plan mode, activity detail, thinking duration, prompt queue

Date: 2026-09-16
Host: macOS, Swift package `AgenticSidebar`

## What was added

| Surface | Change |
| --- | --- |
| `AgentMode` | `build` / `plan`, persisted in `SettingsStore`, sent with every request exactly like `ResponseSpeedMode` |
| Plan instruction | `PLAN MODE`: no writes, no state-changing commands, answer with exactly one fenced `plan` block |
| Plan document | `MarkdownContentView` parses a `plan` fence (case-insensitive, trailing hint allowed, unterminated fence during streaming) into a document card built by `PlanDocumentView` |
| Approval | `ConversationDetailView.planApprovalBar` sits under the newest plan while the session is idle and the composer still says Plan; `Approve & Build` flips the mode and sends the plan back as a user turn |
| Activity detail | `ProviderActivityDescriptor` … `AgentActivity` carry `output` and `diff`; the timeline renders a `+`/`-` diff card, a console card, or the read result |
| Thinking duration | Measured from `startedAt`/`completedAt`; a 1 s `TimelineView` counts up while thinking, the finished row shows the final duration |
| Prompt queue | `QueuedPrompt` (text, attachments, speed, mode); `send` returns `.started` / `.queued` / `.rejected`; the composer shows a removable strip and drains in order |

## Verification

- `swift build --product AgenticSidebar` — clean.
- `swift test` — **217 tests, 0 failures**.
- `AgentModeTests` — instruction text, composition with the speed instruction, OpenAI `instructions`
  field present for Plan and absent for Build, OpenCode prompt prefix, persistence.
- `PlanDocumentParsingTests` — fence becomes a document, case-insensitive language with a hint,
  no nested plan inside a plan, `containsPlanDocument` matches only plan fences.
- `PromptQueueTests` — order preserved across three turns, queued prompt keeps mode and speed,
  cancellation still drains the queue, remove/clear, empty and unconfigured prompts rejected,
  an idle session starts immediately.
- `OpenCodeStreamNormalizerTests` / `OpenCodeProviderRuntimeTests` — `edit` parts produce a diff,
  `read` and `bash` parts produce output, and the finished event carries both.

### Defect found and fixed while verifying

`AgentSession.consume` started a provider stream and only then checked `Task.isCancelled`, so a
turn the user cancelled before it reached the provider still opened a backend stream (a real HTTP
request, and for OpenCode a real session turn) just to tear it down. The cancellation check now
runs first. This also made `testCancellingATurnStillSendsWhatWasQueued` deterministic: the
abandoned stream used to leave a stale continuation that the test gate completed instead of the
live turn, so the session looked permanently busy.

## Limits

- Plan mode is an instruction, not a sandbox: the app deliberately does not touch the provider's
  tool permissions, so a model that ignores the instruction could still edit. The approval bar is
  the product-level gate, not a security boundary.
- The diff/console cards only have content for providers that report tool parts (OpenCode). The
  OpenAI code path has no equivalent event and therefore shows no diff.
- Visual confirmation (mode pill, plan card, diff colours) needs a human running the app; the
  values behind them are unit tested.

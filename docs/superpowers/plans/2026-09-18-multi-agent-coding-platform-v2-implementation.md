# Multi-Agent Coding Platform V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a persistent macOS coding task board that assigns safe provider-capability-aware agent attempts, edits only isolated owned Git worktrees, verifies real build/test evidence, and requires human acceptance.

**Architecture:** Introduce source-level TaskBoard, Workspace and Verification boundaries inside the existing SwiftPM executable. Retain existing chat, GoalEngine and provider runtimes; add a provider-neutral coding-runner contract and transactional task store, with one code-writing attempt per repository in MVP. Keep dispatch disabled until workspace, approval and evidence gates are integrated.

**Tech Stack:** Swift tools 6.2, Swift 6 concurrency, SwiftUI/Observation, XCTest, macOS 26, Foundation Process, Git, system SQLite3 only after toolchain feasibility test, existing OpenCode and direct OpenAI runtimes.

**Spec:** `docs/superpowers/specs/2026-09-18-multi-agent-coding-platform-v2-design.md`

**Status:** Planning document only. Production code has NOT been implemented or tested under this plan. Review and approve both documents before execution.

## Global Constraints

- Deployment target `.macOS(.v26)` and SwiftPM `swift-tools-version: 6.2` remain unchanged.
- Keep one executable and one XCTest target; no new third-party dependencies in MVP. Confirm native SQLite3 module and linker availability before using it.
- `AgenticSidebarApp.swift` remains process-lifetime composition root. SwiftUI projections are `@MainActor`; scheduler/store/process owners are actors.
- Preserve all other agents' existing dirty/untracked files, especially shared `AgentSession.swift` and `ConversationDetailView.swift`. Never reset/stash/stage/commit/overwrite another owner's changes.
- Do not bypass the native `WORKTREE_DIRTY` or project authority checks via raw worktree/clone, shell alternatives or new unrestricted roots. Block and ask for an authorized clean baseline.
- Do not perform implementation, commit, push, merge, PR, deployment or destructive cleanup as part of writing this plan. During future execution commit only explicitly owned paths, when baseline and ownership checks permit it. Push/merge require a separate user decision.
- Default scheduler caps: one active writing attempt per repository, three attempts per task, 3,600 seconds active task time and 300 reported tool calls per attempt; unknown usage remains unknown.
- Never run model-generated shell command strings; verification recipes use fixed executable, argv and canonical working directory with explicit approval.
- In MVP OpenCode is the executable coding adapter. Direct OpenAI is text-only on supplied context and must advertise no repository-read/write/tools. Additional CLIs require separate verified adapter milestones.
- A task is `done` only after fresh build/test/required lint, explicit acceptance-criterion dispositions, review handling and user acceptance of the exact content fingerprint.
- Each code task is TDD: write failing focused XCTest, observe failure, make smallest implementation, observe pass, run regression tests, inspect exact diff and ownership. Fresh verification is required before any completion statement.

## Baseline gate: do not execute Task 1 until ownership is stable

Verified at design-writing time: `/Users/dogan/Desktop/AgenticSidebar`, branch `plan/review-fixes-2026-09-17`, HEAD `cc4f07d`; many tracked and untracked changes from other agents. Some existing Goal sources are untracked. These observations can be stale even minutes later; start with new status. The existing project continuity record also notes mixed ownership in `AgentSession.swift` and `ConversationDetailView.swift`. Do not stage or rewrite those files in the planning task. The new design/spec files do not confer permission to launch an isolated worktree around a dirty-tree safety guard.

**Baseline commands, future execution only:**

```bash
git rev-parse --show-toplevel
git rev-parse HEAD
git status --short --branch
git diff --check
swift build --product AgenticSidebar -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift-format lint -r --strict Sources Tests
```

Record exact HEAD, source-tree digest and command exits. Check `swift-format --version` against CI's pinned `604.0.0` before treating lint evidence as valid. `swift test` may exercise Keychain only when `RUN_KEYCHAIN_TESTS=1`; keep default hermetic behavior and report real-host Keychain separately. If other agents still own dirty code or the checks fail, stop; arrange owner-led commit or separation, do not perform a blanket cleanup. Resume from verified repository state and re-read this plan and spec if the existing architecture changed.

## File ownership map (all are FUTURE modifications)

| Area | Files and single responsibility |
|---|---|
| `TaskBoard/` domain | `CodingTaskModels.swift` immutable IDs/status/stage/roles/budgets; `TaskStateMachine.swift` guarded state transitions; `TaskDependencyGraph.swift` cycle detection and ordering |
| `TaskBoard/` persistence | `TaskRepository.swift` neutral repository port and snapshots; `SQLiteTaskStore.swift` transactions and bound queries; `TaskStoreMigrations.swift` versioned schema |
| `ProviderGateway/` | `CodingAgentRuntime.swift` execution request, normalized events, run cancellation; `CodingAgentCapabilities.swift` truthful feature flags; `CodingAgentRegistry.swift` eligibility checks |
| Adapters | `OpenCodeProvider/OpenCodeCodingAgentAdapter.swift` task-scoped runtime; `OpenAIProvider/OpenAITextCodingAdapter.swift` supplied-context text-only runtime |
| `TaskBoard/` execution | `TaskScheduler.swift` dependencies/lease dispatch; `TaskRecovery.swift` uncertainty and reconciliation; `CodingTaskService.swift` app-facing use cases |
| `Workspace/` | `WorkspaceManaging.swift` port; `WorkspaceManifest.swift` ownership data; `GitWorkspaceManager.swift` preflight/creation/reconciliation; `GitCommandRunner.swift` fixed argv process execution |
| `Verification/` | `VerificationRecipe.swift` command provenance; `VerificationResolver.swift` explicit recipe selection; `VerificationRunner.swift` execution and evidence; `AcceptanceGate.swift` conjunctive completion policy |
| Board UI | `Views/TaskBoard/TaskBoardView.swift`, `TaskDetailView.swift`, `TaskActivityView.swift`, `TaskActionBar.swift`; `TaskBoard/TaskBoardStore.swift` main-actor projection |
| App integration | Touch `App/AgenticSidebarApp.swift` and `Views/RootChatView.swift` only after baseline owners have finalized edits; keep `AgentCore/AgentSession.swift` and `Views/ConversationDetailView.swift` untouched in MVP unless a reviewed interface change is indispensable |
| Tests | New `Tests/AgenticSidebarTests/` files named in each task; preserve all existing test source |

The new directories are package-source folders, not extra SwiftPM targets. File names and interfaces below are authoritative within this plan; re-review if an existing concurrent agent independently creates any of them.

---

## Phase 0 — Stabilize and verify the baseline

### Task 1: Ownership and baseline freeze

**Files:** Read only: `Package.swift`, `.github/workflows/ci.yml`, `README.md`, `Sources/AgenticSidebar/AgentCore/GoalOrchestrator.swift`, `Sources/AgenticSidebar/ProviderGateway/ProviderRuntime.swift`, plus Git status/diff. Write only a review record in the phase implementation branch after it is independently authorized; no source mutation.

**Interfaces:** Produces a reviewed `BaselineRecord` in the execution report (HEAD, branch, workspace cleanliness, source digest, exact verification exits and artifact ownership); later task work cannot start without it.

- [x] Step 1: Ask each running agent to conclude or isolate its owned changes. Re-read project continuity and `git status --short --branch`; inventory unstaged, staged and untracked files by owner.
- [x] Step 2: Reject continuation if mixed ownership remains or native worktree guard rejects the operation. Do not reset, stash, clone or force-switch; do not create a parallel path to evade the guard.
- [x] Step 3: On an owner-approved stable tree, capture HEAD/branch/status and SHA/digest, then run all baseline commands above without truncating output or hiding nonzero exit codes.
- [x] Step 4: Compare the old and new file inventories. Ensure existing Goal, session, UI and question integrations are preserved; capture CI/keychain/lint environmental limitations separately.
- [x] Step 5: Obtain explicit approval for an isolated feature execution workspace. Stop if unavailable. There is no commit/push in this task.

**Gate:** stable authorized baseline, exact command evidence and no foreign-file ownership ambiguity. Until then all subsequent tasks are blocked.

## Phase 1 — Durable task domain and local persistence

### Task 2: Task model and legal state machine

**Files:** Create `Sources/AgenticSidebar/TaskBoard/CodingTaskModels.swift`, `Sources/AgenticSidebar/TaskBoard/TaskStateMachine.swift`; test `Tests/AgenticSidebarTests/CodingTaskStateMachineTests.swift`.

**Interfaces:** `CodingProject`, `CodingTask`, `CodingAcceptanceCriterion`, `TaskDependency`, `TaskAttempt`, `AgentRole`, `TaskStatus`, `TaskStage`, `TaskBlockReason`, `ExecutionBudget`, `TaskAction`, `TaskTransitionContext`; `TaskStateMachine.transition(_:action:context:) throws -> CodingTask`. Task carries monotonically increasing `version`; transition returns a changed value rather than mutating persisted state.

- [x] Step 1: Write `testCannotCompleteWithoutAcceptance`, `testCancelledAttemptCannotBecomeDone`, `testVersionAdvancesOnLegalTransition` with exact initial statuses/actions; expected failed compile because new types do not exist.
- [x] Step 2: Run `swift test --filter CodingTaskStateMachineTests` and record RED (nonzero). A compiler failure in unrelated files blocks this task instead of counting as its RED test.
- [x] Step 3: Implement value types and guarded transitions from spec section 5. Require review evidence plus matching approval context for `review→done`; disallow direct `ready→done`, `done→running` and any terminal stale update.
- [x] Step 4: Run the same filter to GREEN; add negative cases for missing criteria and changed fingerprint. Run `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors`.
- [x] Step 5: Inspect only owned paths and obtain review before a narrowly scoped, authorized commit. No push.

**Gate:** deterministic state machine, explicit invalid-transition errors and tests for all seven statuses.

### Task 3: Dependency graph and readiness

**Files:** Create `Sources/AgenticSidebar/TaskBoard/TaskDependencyGraph.swift`; test `Tests/AgenticSidebarTests/TaskDependencyGraphTests.swift`.

**Interfaces:** `TaskDependencyGraph.add(_:to:tasks:) throws -> [TaskDependency]`; `TaskDependencyGraph.readyIDs(tasks:dependencies:) -> [UUID]` ordered by priority, creation time and UUID. Input edges and tasks are project-scoped; output cannot reference a missing task or another project.

- [x] Step 1: Add tests for direct/indirect cycle, self-edge, duplicate edge, cross-project edge, missing predecessor, and a dependency in `review` rather than `done`.
- [x] Step 2: Run `swift test --filter TaskDependencyGraphTests` and capture a relevant RED.
- [x] Step 3: Implement cycle detection using iterative DFS with a visited/in-stack set and deterministic ready ordering; no mutation of caller input on rejection.
- [x] Step 4: Re-run focused GREEN and a 1,000-task acyclic graph case that terminates without recursion overflow; run full `swift test` at the current isolated revision.
- [x] Step 5: Review and checkpoint the domain/graph deliverable without staging unrelated paths.

**Gate:** no cyclic schedule; prerequisites must actually be `done`.

### Task 4: Transactional SQLite repository

**Files:** Create `Sources/AgenticSidebar/TaskBoard/TaskRepository.swift`, `SQLiteTaskStore.swift`, `TaskStoreMigrations.swift`; test `Tests/AgenticSidebarTests/TaskStoreTests.swift` and `TaskStoreMigrationTests.swift`. Modify `Package.swift` only if the native SQLite3 linker requirement is independently proved and the modification is owned/approved.

**Interfaces:** `CodingTaskRepository` methods `snapshot(projectID:) async throws -> CodingBoardSnapshot`, `createTask(_:) async throws`, `addDependency(_:) async throws`, `transition(taskID:expectedVersion:action:) async throws -> CodingTask`, `claimAttempt(taskID:expectedVersion:attempt:) async throws -> TaskAttempt`, `appendEvent(_:) async throws`, `recordEvidence(_:) async throws`; no direct SQL leaks to UI. `CodingBoardSnapshot` includes project-scoped tasks, dependency edges and current attempt summaries. Transactions include expected-version and unique active-attempt checks.

- [x] Step 1: Write a minimal SQLite3 import/link feasibility test for the approved host toolchain. If import or linker fails, stop and seek a separate store decision; do not silently add GRDB or raw bridging.
- [x] Step 2: Add failing tests for create/reload, persisted agent profile, project isolation, stale version, duplicate task claim, two different tasks racing for the same repository writing lease, FK violation, migration rollback and unreadable/corrupt store being preserved rather than erased.
- [x] Step 3: Run `swift test --filter TaskStoreTests` and `swift test --filter TaskStoreMigrationTests`; confirm failures are feature-specific.
- [x] Step 4: Implement schema v1 including `agent_profiles` and `repository_leases`, `PRAGMA foreign_keys=ON`, WAL, prepared/bound SQL, exclusive per-repository writer claim, explicit transactions, migration transaction and read-only error state. Lease expiry remains blocked pending ownership reconciliation. Save only redacted typed event data; no API keys, arbitrary prompt bodies or complete terminal output.
- [x] Step 5: Re-run filters, terminate/reopen the store and assert byte-equivalent task/criteria/attempt reconstruction. Run `swift test` plus `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors`.
- [x] Step 6: Review schema and migrations as an independently revertible deliverable.

**Gate:** restart-stable store, race-safe claim and no lost data on incompatible schema.

## Phase 2 — Honest provider-neutral coding interface

### Task 5: Coding agent contract and capability registry

**Files:** Create `Sources/AgenticSidebar/ProviderGateway/CodingAgentCapabilities.swift`, `CodingAgentRuntime.swift`, `CodingAgentRegistry.swift`; test `Tests/AgenticSidebarTests/CodingAgentRegistryTests.swift`, `CodingAgentContractTests.swift`.

**Interfaces:** `CodingAgentCapabilities` has `textAnalysis`, `workspaceRead`, `workspaceWrite`, `tools`, `interactiveApproval`, `sessionResume`, `cancellable`, `structuredEvents`, `usageReporting` as independent flags; `CodingAgentExecutionRequest` carries taskID, attemptID, generation, role, configuration, objective, acceptance criteria, owned workspace identity and immutable policy; `CodingAgentEvent` is provider-neutral; `CodingAgentRun.events` bounded, `cancel() async`; `CodingAgentRuntime.capabilities(for:) async`, `start(_:) async throws -> CodingAgentRun`, `release(attemptID:) async`. `CodingAgentRegistry.eligible(configuration:required:)` returns supported or explicit missing capability details.

- [x] Step 1: Fake two adapters with complementary capabilities. Write tests that an OpenAI text-only runtime cannot pass `workspaceWrite`/`tools` eligibility, a nonexistent provider cannot fallback silently, and missing cancellation is not advertised as present.
- [x] Step 2: Run both focused filters and observe RED.
- [x] Step 3: Implement the immutable request/normalized event and truthful capability registry. Ensure terminal success requires an actual terminal event; EOF is interruption.
- [x] Step 4: Add stream backpressure and cancellation tests with bounded fake producer/consumer; prevent stale `(taskID, attemptID, generation)` events from changing another attempt.
- [x] Step 5: Focused GREEN, full `swift test`, owned diff review; no live coding dispatch until Phase 4.

**Gate:** no model-name inference or silent provider substitution; explicit missing-feature reason.

### Task 6: OpenCode coding adapter and task ownership

**Files:** Create `Sources/AgenticSidebar/OpenCodeProvider/OpenCodeCodingAgentAdapter.swift`; modify `OpenCodeProvider/OpenCodeProviderRuntime.swift` and `OpenCodeProvider/OpenCodeClient.swift` only for narrowly reviewed missing working-directory/identity interfaces after reading current source; test `Tests/AgenticSidebarTests/OpenCodeCodingAgentAdapterTests.swift` and extend `OpenCodeProviderRuntimeTests.swift` if interfaces change.

**Interfaces:** Adapter conforms to `CodingAgentRuntime`; task/attempt owns a dedicated application+remote session mapping, distinct from active chat; the request's workspace canonical path must be proven to be the backend's real working directory before `workspaceWrite` is true. Parent/child permission events are attributed to verified ancestry; `release(attemptID:)` cleans owned session only.

- [x] Step 1: Write RED tests for distinct chat/task remote sessions, wrong workspace refusal, child permission attribution, stream interruption and cancel/release without touching another chat's session.
- [x] Step 2: Run `swift test --filter OpenCodeCodingAgentAdapterTests` and capture feature-specific RED.
- [x] Step 3: Map existing OpenCode events and permission handling through new port without weakening `PermissionApprovalCenter`; confirm installed OpenCode supports setting and reading task working directory, otherwise return `unsupportedCapability` and keep live writing disabled.
- [x] Step 4: GREEN mocks, then a separately authorized real-host integration test with a disposable approved clean repository/worktree verifying actual `pwd`, a harmless file edit, event completion, approval and cancellation. Do not execute in the user's dirty source checkout.
- [x] Step 5: Run existing `OpenCodeProviderRuntimeTests` and full `swift test`; record vendor/version and tested capability matrix.

**Gate:** live worktree containment actually proven; if live test unavailable, adapter stays disabled for writing and milestone remains unverified.

### Task 7: Direct OpenAI text-only adapter

**Files:** Create `Sources/AgenticSidebar/OpenAIProvider/OpenAITextCodingAdapter.swift`; test `Tests/AgenticSidebarTests/OpenAITextCodingAdapterTests.swift`. Do not modify direct provider networking unless an owned, explicitly reviewed defect is demonstrated.

**Interfaces:** Adapter conforms to `CodingAgentRuntime`, wraps existing `OpenAIProviderRuntime` streaming with supplied bounded text context and declares `workspaceRead=false`, `workspaceWrite=false`, `tools=false`, `interactiveApproval=false`. `start(_:)` rejects any implementation, repository scan, independent code review or verification request without required capabilities.

- [x] Step 1: RED tests for truthful flags, read/write denial, no prompt leakage into persisted event log, cancellation and text-only planning on a supplied fixture.
- [x] Step 2: Run `swift test --filter OpenAITextCodingAdapterTests` and capture RED.
- [x] Step 3: Implement the minimal text-only mapping. An OpenAI model being available via OpenCode does not alter the direct adapter's flags.
- [x] Step 4: GREEN and run `OpenAIProviderRuntimeTests` plus full `swift test`.

**Gate:** no UI claim of cross-provider tool parity; no direct API writing path enabled.

## Phase 3 — Scheduler and restart recovery

### Task 8: Deterministic scheduler, attempt budgets and lease ownership

**Files:** Create `Sources/AgenticSidebar/TaskBoard/TaskScheduler.swift`; test `Tests/AgenticSidebarTests/TaskSchedulerTests.swift`; expand `TaskRepository.swift`/`SQLiteTaskStore.swift` only for versioned claim/lease operations proven necessary by tests.

**Interfaces:** `TaskScheduler.schedule(projectID:) async`, `pause(taskID:) async`, `stop(taskID:) async`, `retry(taskID:) async`; ports are injected repository, provider registry, workspace manager and verifier. `TaskLease` belongs in `CodingTaskModels.swift`: attemptID, generation, owner nonce, expiration. `schedule` is inert for live execution until Phase 4 workspace preflight returns an owned workspace.

- [x] Step 1: RED tests with fake clock/runner for dependency ordering, double scheduler race, max one active writer, maximum three attempts, time/tool-call budget, blocked unsupported runtime and stale completion.
- [x] Step 2: Run `swift test --filter TaskSchedulerTests`; observe test-specific RED.
- [x] Step 3: Implement deterministic eligibility, atomic repository claim, monotonically incremented generation and scope-limited retry policy. Error on missing usage must not be rewritten as zero; budget exhaustion blocks without infinite retry.
- [x] Step 4: Add repeated concurrent claim test (100 contenders, one winner) and pause-vs-stop cases; run focused GREEN then full `swift test`.
- [x] Step 5: Review cross-actor isolation and lifecycle ownership; keep actual filesystem writes disabled.

**Gate:** no double claim, no late stale mutation and no unchecked write dispatch.

### Task 9: Recovery and uncertainty reconciliation

**Files:** Create `Sources/AgenticSidebar/TaskBoard/TaskRecovery.swift`; test `Tests/AgenticSidebarTests/TaskRecoveryTests.swift`; modify `SQLiteTaskStore.swift` only as explicitly tested for recovery markers.

**Interfaces:** `TaskRecovery.reconcile(projectID:) async -> RecoveryReport` inspects persisted attempts, provider session identity and workspace ownership through injected ports; unverified in-flight attempts become `blocked(uncertainExecution)`. No side-effectful retry during launch.

- [x] Step 1: RED tests for crash after claim, after provider submission, after edit before evidence, orphan process with foreign owner, expired lease and delayed callback after retry.
- [x] Step 2: Run `swift test --filter TaskRecoveryTests` and capture RED.
- [x] Step 3: Implement conservative reconciliation, nonce/executable ownership checks, explicit user recovery choice and generation invalidation. Unknown PID alone is never enough to terminate a process.
- [x] Step 4: GREEN, simulate close/reopen against real temporary SQLite store, run full `swift test`.

**Gate:** uncertain side effects never trigger automatic duplicated execution.

## Phase 4 — Managed Git workspace and safety

### Task 10: Worktree preflight, ownership and guarded retirement

**Files:** Create `Sources/AgenticSidebar/Workspace/WorkspaceManaging.swift`, `WorkspaceManifest.swift`, `GitWorkspaceManager.swift`, `GitCommandRunner.swift`; test `Tests/AgenticSidebarTests/GitWorkspaceManagerTests.swift`. Read existing `AgentCore/GoalSafety.swift` and native MCP guard semantics; do not weaken or replace them.

**Interfaces:** `WorkspaceManaging.preflight(project:task:) async -> WorkspacePreflight`, `createOwnedWorkspace(task:attempt:base:) async throws -> WorkspaceRecord`, `inspect(workspaceID:) async -> WorkspaceInspection`, `retire(workspaceID:approval:) async throws`. `GitCommandRunner.run(executable:arguments:directory:)` uses `Process` and fixed argv only; no `sh -c` or interpolated user-supplied git flags. Manifest includes taskID/attemptID/base SHA/common-dir identity/nonce.

- [x] Step 1: RED tests with temporary fixture repository: dirty tracked/untracked root, protected branch, symlink escape, path outside authorized scope, fake foreign manifest, mismatched Git common dir, and dirty workspace retirement refusal.
- [x] Step 2: Run `swift test --filter GitWorkspaceManagerTests`; observe relevant RED. Tests may create disposable temp Git repos only within authorized test scope and cannot invoke a raw worktree to bypass an active real project guard.
- [x] Step 3: Implement preflight and exact ownership, guard-specific errors, creation only after the official authority preflight, manifest write and atomic store record. Refuse operation if guard or clean-baseline validation fails.
- [x] Step 4: Add tests for source branch/hash unchanged and byte-identical untracked files after successful disposable attempt; assert cleanup refuses unknown or dirty owned worktrees and reports manual inspection path.
- [x] Step 5: GREEN, full `swift test`, real-host authorized disposable worktree smoke using native managed operations only; check no orphaned worktree or child process. If authority cannot grant access, mark real-host integration blocked and leave live dispatch disabled.

**Gate:** foreign files never changed; worktree provenance and disposal independently verified.

## Phase 5 — Project verification and approval gates

### Task 11: Versioned verification recipe and actual process evidence

**Files:** Create `Sources/AgenticSidebar/Verification/VerificationRecipe.swift`, `VerificationResolver.swift`, `VerificationRunner.swift`; test `Tests/AgenticSidebarTests/VerificationResolverTests.swift`, `VerificationRunnerTests.swift`. Extend `TaskBoard/CodingTaskModels.swift` and `SQLiteTaskStore.swift` for evidence storage only as required by tests.

**Interfaces:** `VerificationRecipe` has version, trusted source, ordered `VerificationStep(executable, arguments, relativeWorkingDirectory, timeoutSeconds, required)`; `VerificationResolver.resolve(repository:) async throws -> VerificationRecipe` reads known project CI/script metadata and requires explicit approval for any non-standard execution; `VerificationRunner.verify(recipe:workspace:) async -> [VerificationEvidence]` records exitCode, timedOut, clipped redacted output and exact workspace fingerprint. CLI invocation is argv-only.

- [x] Step 1: RED recipe tests for this repository's exact build/test plus optional-if-version-matched `swift-format 604.0.0`, unknown project, invalid executable/path escape and required missing tool. Recipes never silently infer unsafe commands from file extension.
- [x] Step 2: RED runner tests for build failure preventing dependent test execution, test nonzero, missing required lint, cancellation/timeout and fingerprint changing between steps.
- [x] Step 3: Run both focused filters and record RED.
- [x] Step 4: Implement trusted recipe resolution, bounded process output, deadline enforcement and evidence fingerprint checks. Record skipped/unavailable explicitly. Real host tests must use a disposable authorized worktree.
- [x] Step 5: GREEN filters, full `swift test`, then fresh build/test/lint in exact approved workspace. Never report success based on a tail pipeline exit code alone.

**Gate:** only actual command exit codes and correct revision yield verification PASS.

### Task 12: Review findings, scoped approval and completion decision

**Files:** Create `Sources/AgenticSidebar/Verification/AcceptanceGate.swift`; place `ReviewFinding` and `TaskApproval` in `TaskBoard/CodingTaskModels.swift`; extend `TaskRepository.swift` and `SQLiteTaskStore.swift` for findings/approvals; test `Tests/AgenticSidebarTests/AcceptanceGateTests.swift` and `TaskApprovalTests.swift`.

**Interfaces:** `AcceptanceGate.evaluate(task:attempt:evidence:findings:approvals:currentFingerprint:requiredSteps:) -> AcceptanceDecision` returns `.readyForHumanReview` or `.blocked(reasons)` or `.accepted`; there is no completion boolean missing reasons. `requiredSteps` was added during execution (2026-09-19) because the resolver marks an unavailable pinned lint as optional; the hardcoded `["build","test","format"]` policy would have blocked such machines permanently. Default policy is `AcceptanceGate.swiftPMRequiredSteps = ["build","test"]`; a failed optional step still blocks via `.optionalStepFailed`. `TaskApproval` binds action, task ID, attempt ID, exact content fingerprint, actor (non-blank) and timestamp; changed content revokes validity. Evidence binding is content-bound + task-scoped (taskID + fingerprint, attempt-agnostic); approvals are attempt-bound. `accept` is the only MVP action allowed to move to `done`; merge/push/discard workspaces are separate future approvals.

- [x] Step 1: RED matrix: failed build, failed tests, stale fingerprint, absent required lint, open high finding, unset criterion, missing user acceptance, wrong attempt approval, and changed file after approval each deny done.
- [x] Step 2: Run `swift test --filter AcceptanceGateTests` and `swift test --filter TaskApprovalTests`; verify relevant RED.
- [x] Step 3: Implement exact fingerprint/evidence and human criterion gates; a model statement 'all tests passed' is merely text, not evidence. Dismissal of a finding must record human actor and reason; cannot happen implicitly.
- [x] Step 4: GREEN filters and full `swift test`; verify a passing complete fixture reaches done only after matching acceptance.

**Gate:** no stale or fabricated evidence can close a task.

## Phase 6 — Native board and end-to-end MVP

### Task 13: App-facing service and main-actor view model

**Files:** Create `Sources/AgenticSidebar/TaskBoard/CodingTaskService.swift`, `TaskBoardStore.swift`; test `Tests/AgenticSidebarTests/CodingTaskServiceTests.swift` and `TaskBoardStoreTests.swift`.

**Interfaces:** `CodingTaskService` exposes project/task creation, dependency changes, start/pause/resume/stop/retry, review and acceptance through injected scheduler/repository; `@MainActor @Observable TaskBoardStore` exposes immutable card/detail projections, loading/error state and action availability, never raw SQL or concrete OpenCode types.

- [x] Step 1: RED tests for create/reload, stale user action, unavailable runtime, concurrent action de-duplication, backend rejection not optimistically shown as successful and switching board selection without cancelling chat.
- [x] Step 2: Run focused tests and capture RED.
- [x] Step 3: Implement service and main-actor projection with bounded event coalescing, explicit result/throw handling, task-local spinner and no auto-execution on view appear.
- [x] Step 4: GREEN, full `swift test` and target build with warnings as errors.

**Gate:** board UI talks only to the service, not to providers, Git or SQLite directly.

### Task 14: Board, detail, activity and approval SwiftUI surfaces

**Files:** Create `Sources/AgenticSidebar/Views/TaskBoard/TaskBoardView.swift`, `TaskDetailView.swift`, `TaskActivityView.swift`, `TaskActionBar.swift`; test `Tests/AgenticSidebarTests/TaskBoardPresentationTests.swift` and `TaskBoardAccessibilityTests.swift`.

**Interfaces:** Board has Backlog/Ready/Running/Review/Done columns, prominent Blocked filter and Cancelled history; task inspector includes criteria, dependencies, attempt history, provider capability, verified worktree/diff/evidence, review findings and content-fingerprint-scoped approval. Action buttons invoke `CodingTaskService` via `TaskBoardStore` only.

- [x] Step 1: RED presenter tests for each state, missing capability reason, stale verification badge, pause/resume action matrix and no automatic status mutation from drag/drop.
- [x] Step 2: Run `swift test --filter TaskBoardPresentationTests` and `swift test --filter TaskBoardAccessibilityTests`; record RED.
- [x] Step 3: Implement lazily rendered cards, detail view and action bar; keyboard tab order and VoiceOver labels include status/reason, not just color. An unavailable runtime displays a disabled explanatory action.
- [x] Step 4: GREEN presenter tests and target build; real-host smoke: create/select task, keyboard navigation, stop while streaming, interrupted task remains visible and chat transcript stays intact. — Not: board henüz app kompozisyonuna bağlı değil (Task 15); presenter düzeyinde smoke ve hedef build doğrulandı, gerçek-host UI smoke Task 15'e devredildi.

**Gate:** visual board reflects persisted truth; no fake progress or automatic accept.

### Task 15: Process composition and integrated task run

**Files:** Modify narrowly `Sources/AgenticSidebar/App/AgenticSidebarApp.swift` and `Sources/AgenticSidebar/Views/RootChatView.swift`; create `Tests/AgenticSidebarTests/MultiAgentCodingIntegrationTests.swift`; extend existing `BackendRestartResilienceTests.swift` only if owned reviewed integration requires it. Leave `AgentSession.swift`, `ConversationDetailView.swift` and `GoalPanelView.swift` unchanged unless a new explicit approval is obtained.

**Interfaces:** One process-lifetime repository/store/scheduler/registry/workspace/verifier/service is constructed at app composition root and injected into board. App shutdown requests owned running-task cancellation, flushes events, and uses existing OpenCode server manager lifecycle without killing unrelated processes. Chat and `/goal` behavior are independent.

- [ ] Step 1: RED integration test: create a task, enforce dependency, approve execution, claim one attempt in a disposable owned worktree, receive fake OpenCode events, run fake recipe evidence, require matching user acceptance, persist/reopen and confirm done once.
- [ ] Step 2: RED crash test: stop after provider reports an edit but before evidence persistence; launch again and confirm blocked uncertainty, not duplicate code-writing.
- [ ] Step 3: Run `swift test --filter MultiAgentCodingIntegrationTests`, verify RED, then wire composition and service only after previous phases' gates are green.
- [ ] Step 4: GREEN integration and all existing session/Goal tests; run fresh `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors`, `swift test -Xswiftc -warnings-as-errors`, pinned `swift-format lint -r --strict Sources Tests`, and `git diff --check` at the exact content digest.
- [ ] Step 5: In a separately authorized disposable repository run real OpenCode E2E: start → edit in owned worktree → observed backend termination → real recipe build/test → review → human accept; separately exercise cancellation, provider restart and app restart. Record backend and model identifiers, capabilities and failures honestly.
- [ ] Step 6: Native host regression: Dock-less launch, existing chat and `/goal`, permission routing, app shutdown/orphan cleanup, Board VoiceOver/keyboard, and unchanged main checkout. Inspect all changed paths and exact ownership; stage only approved paths if and when a clean authorized commit is permitted. Never auto-push/merge.

**MVP gate:** A1–A11 in the spec each have source-linked evidence; disabled features are clearly labeled; no other-agent changes included. If real provider or macOS tests are unavailable, label MVP integration unverified rather than claiming completion.

## Phase 7 — Independently approved extensions (NOT part of MVP implementation)

### Task 16: New CLI adapters and language-specific verification contracts

**Files once a separate adapter design is approved:** `Sources/AgenticSidebar/ProviderGateway/CLICodingAgentContract.swift`, `Sources/AgenticSidebar/Verification/AdditionalLanguageRecipes.swift`, and adapter-specific source/test pairs under named provider folders. Do not create a generic adapter that guesses undocumented CLI flags.

**Interfaces:** each CLI implementation must conform to `CodingAgentRuntime` and demonstrate pinned installed version, worktree-cwd proof, structured events/terminal outcomes, process-tree cancellation, ownership-safe approvals and redacted output. Each recipe family must produce trusted fixed argv from inspected CI/scripts rather than inferred arbitrary commands.

- [ ] Step 1: Choose ONE installed CLI and document its actual version, published invocation/event/permission contract, authentication ownership and failure modes; request separate design approval if any contract is missing.
- [ ] Step 2: Add adapter-specific RED contract tests: unsupported versions rejected, no write before cwd proof, unrecognized permission request rejected, child process cleanup, cancellation and secret redaction.
- [ ] Step 3: Implement only documented capabilities, then run focused GREEN, full regressions and disposable real-host integration. Mark untested models/runtimes unsupported.
- [ ] Step 4: For one new language family, inspect exact project CI/test recipe, add RED resolver/runner tests and real disposable-project evidence before marking it supported.

**Gate:** provider- and language-specific test matrix, not a global 'all providers supported' switch. Parallel writing, PR creation, automatic merge and deploy each require separate future specifications and approvals.

## Coverage review and execution handoff

Spec section mapping: domain/schema §§4–5 → Tasks 2–4; provider §6 → Tasks 5–7 and future Task 16; workspace §7 → Task 10; verification/approvals §8 → Tasks 11–12; native UI §9 → Tasks 13–15; recovery/privacy §10 → Tasks 4, 8–10, 15; acceptance §11 → all gates and Task 15; sequencing §12 → Phases 0–7. Every new source has a named test or integration gate. Recheck names and signatures against the code and this mapping before starting implementation; a conflict requires plan revision, not guessing.

At handoff, provide the spec, this plan, freshly verified clean baseline and per-file ownership inventory. Each engineer or delegated agent must implement exactly one reviewed task at a time in an authorized isolation mechanism, using TDD and fresh evidence. Other agents continue to own their existing edits. This planning task creates documentation only and does not authorize implementation, commit or publication.

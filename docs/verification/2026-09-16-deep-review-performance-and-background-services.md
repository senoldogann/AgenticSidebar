# Deep review: performance, background services, and computer-use proof

Date: 2026-09-16
Branch: `feat/chat-ux-streaming-activities-enter`
Findings ledger: `TODO_code-reviewer.md` (Round 3)

This note holds the commands and their output. Every number quoted in the review
comes from here.

## 1. Baseline

```
$ swift build -Xswiftc -warnings-as-errors | tail -2
[127/128] Applying AgenticSidebar
Build complete! (8.32s)

$ swift test -Xswiftc -warnings-as-errors | tail -3
Executed 460 tests, with 2 skipped and 0 failures (0 unexpected) in 6.373 (6.401) seconds
```

The two skips are the opt-in ones: the keychain test and the live-helper protocol
test.

## 2. What is running, and what it costs

Three samples, four seconds apart, on an idle machine:

```
$ for i in 1 2 3; do ps -eo pid,%cpu,rss,command | grep -E "[A]genticSidebar$|[o]pencode.exe serve|[c]li.js stdio"; sleep 4; done
7875 cpu=0.0 rss=149MB   AgenticSidebar            (the app)
7878 cpu=2.7 rss=763MB   opencode.exe serve … --pure
7882 cpu=0.0 rss=83MB    node … chatgpt-system/dist/cli.js stdio …
7875 cpu=0.0 rss=149MB
7878 cpu=2.3 rss=763MB
7882 cpu=0.0 rss=83MB
7875 cpu=0.0 rss=149MB
7878 cpu=2.4 rss=763MB
7882 cpu=0.0 rss=83MB
```

Both background monitors are disabled on this machine, which is why the app is
flat:

```
$ defaults read com.dogan.AgenticSidebar | grep -iE "autoAnalyze|autoSubmit"
    "settings.autoAnalyzeScreenshots" = 0;
    "settings.autoSubmitClipboard" = 0;
```

### The backend's idle CPU is not app chatter

Twelve minutes of the app's unified log, deduplicated: launch, server start, MCP
registration, two shortcuts, two clean shutdowns — **no repeating entry**. A
reconnect storm or a polling loop would show up here as a line repeated hundreds
of times.

```
$ log show --last 12m --info --predicate 'subsystem == "com.dogan.AgenticSidebar"' | sort | uniq -c | sort -rn
   2 … Registered global shortcut with key code 11 and modifiers 256
   1 … Registered the chatgpt-system MCP server for computer use
   1 … OpenCode 1.18.31 listening on authenticated loopback
   1 … Application launched with accessory activation policy
   1 … Termination signal handled; exiting
   1 … Managed shutdown completed
```

The only periodic fetch the app has is the agent's task list, and it is
event-driven: `refreshTodos()` is called when a `todo` activity starts and once at
the end of a turn (`AgentCore/AgentSession.swift`), never per text delta.

## 3. The three fixed findings

### 3.1 `codesign` on the main actor

Before: `ComputerUseStatus.refresh` (`@MainActor`) called
`ComputerUseHelperStatus.inspect(…, signatureReader:)`, whose implementation ran
`/usr/bin/codesign --display --verbose=4` with `readDataToEndOfFile()` and
`waitUntilExit()` — on the thread that draws the window, every time the card
appeared.

After: the requirement is `async`, the implementation spawns inside
`Task.detached`, and the sync `inspect` only touches the filesystem. The signature
is attached afterwards with `addingSigning(_:)`.

### 3.2 The per-second Desktop scan

Before, `recentScreenshotFileURLs()` evaluated
`hasScreenshotName(file) || isScreenCaptureByMetadata(file)` for every entry, so
`MDItemCreateWithURL` ran for every PDF, folder and text file on the Desktop —
once a second, on the main actor.

After, one predicate decides, extension first:

```
$ swift test --filter testSpotlightIsOnlyAskedAboutImagesWhoseNameSaysNothing
candidates: ["Screen Shot ….png", "holiday.png", "invoice.pdf", "notes.txt", "projects", "archive.zip", "Screenshot 2026.png.bak"]
matched:    ["Screen Shot ….png"]
queries:    ["holiday.png"]        ← the only file Spotlight was asked about
```

and the scan itself runs in `Task.detached`, serialized by an `isTicking` guard.

### 3.3 The sweep that could kill a peer instance

Before, a recorded pid that was alive with a matching command line was killed —
including the server of a *running* second copy of the app.

After, a lease is acted on only when the process is orphaned:

```
$ swift test --filter "OpenCodeServerLedgerTests|OpenCodeProcessTreeTests"
testTheReapDecision                          passed   (six branches)
testAReapEndsAServerRecordedInALease         passed   (real SIGKILL, injected observation)
testAReapLeavesAServerThatStillHasALiveParentAlone passed (real systemFacts; parent == the test runner)
Executed 8 tests, with 0 failures
```

## 4. Computer-use, end to end

`script/verify-computer-use.mjs` drives the same MCP server the app registers,
with the app's own arguments, and calls the real tools. It is read-only: nothing
types, clicks or moves the pointer.

```
$ node script/verify-computer-use.mjs
root:   /Users/dogan/Desktop/chatgpt-system
helper: /Users/dogan/.chatgpt-system/ChatGPTSystemComputerRuntime.app

PASS  helper installed               — /Users/dogan/.chatgpt-system/ChatGPTSystemComputerRuntime.app
PASS  MCP handshake                  — chatgpt-system 0.1.0
PASS  tools/list                     — 19 computer_* and 3 session_authority_* tools (of 80)
PASS  computer_run_js is exposed for the app to deny — present, so the app's deny rule is load-bearing
PASS  computer_health                — state=running accessibility=true screenRecording=true inputMonitoring=true eventPosting=true
PASS  session_authority_start        — profile=admin
PASS  computer_observe               — frontmost application: Freebuff
PASS  computer_screenshot            — 1710×1112 px, 868 KiB of PNG

8/8 steps passed
```

- `computer_observe` returning the frontmost application is real accessibility
  data, not a flag.
- `computer_screenshot` returning 868 KiB of PNG is Screen Recording doing its
  job, not `CGPreflightScreenCaptureAccess` reporting that it would.

The configuration the app writes matches what the tests assert:

```
$ python3 -c '…managed-config.json…'
computer rules in file order: [('chatgpt-system_*', 'deny'), ('chatgpt-system_computer_*', 'ask'),
 ('chatgpt-system_session_authority_*', 'ask'), ('chatgpt-system_computer_health', 'allow'),
 ('chatgpt-system_computer_run_js', 'deny')]
instructions: ['…/OpenCode/computer-use-instructions.md']
```

## 4b. The agent has already driven it through the app

The last link is the app's own approval pipeline, and it has production evidence
rather than a test double. The audit log (`…/OpenCode/audit.jsonl`) holds eleven
decisions for real `chatgpt-system_*` calls made by an agent turn today:

```
tools:   session_authority_start ×2, session_authority_end ×1, computer_observe ×2,
         computer_screenshot ×4, computer_open_app ×1, computer_pointer_position ×1
replies: once ×11   (source: policy)
```

`computer_open_app` is the state-changing one, and it was approved through the
same card as the read-only ones. So the full path is proven with real traffic:
agent turn → OpenCode → the app's per-tool approval → `chatgpt-system` MCP →
signed helper → macOS, and back.

## 5. Shutdown leaves nothing behind

`SIGTERM` is the signal the development script sends and the one AppKit never
delivers on its own; this exercises the ledger and the process-tree signal path in
production.

```
=== before ===
7878.json            (one lease)
app=7875, children: 7878

=== after kill -TERM 7875 ===
app alive: 0
servers matching the app fingerprint: 0
mcp cli.js children: 0
helper hosts: 0
leases left: 0

log: "Managed shutdown completed" → "Termination signal handled; exiting"
```

## 6. What was left alone, and why

Two `opencode serve` processes predate this feature by days and do **not** match
the app's launch fingerprint (no `--pure`; `--port 41231` and `--hostname=…`
syntax instead of the app's own):

```
 10904     1  201MB  11:45:40  opencode serve --port 41231
 18276     1  291MB  11-23:56  opencode serve --hostname=127.0.0.1 --port=60848
```

They are the exact case the fingerprint exists to protect: a server started by
hand in a terminal is not the app's to kill. They were reported rather than
reaped. A 16-day-old Selenium `uc_driver` from another project is running
alongside them.

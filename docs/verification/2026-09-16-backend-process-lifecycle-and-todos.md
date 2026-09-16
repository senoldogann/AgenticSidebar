# Backend process lifecycle, MCP minimality, and the todo checklist — 2026-09-16

## The report

Activity Monitor showed **36 `opencode` processes** on this machine, each around
350 MB, plus the node, python and `uv` trees behind them: 14 of 16 GB of memory in
use, 9.5 GB of swap. One app was running. The question was whether every launch
starts another server and leaves the previous one alive.

It did.

## What was actually happening

```
$ ps -eo pid,ppid,pgid,etime,command | grep 'opencode serve'
 2400     1  2400  11:43:06 /opt/homebrew/bin/opencode serve --hostname 127.0.0.1 --port 63188 --pure
 3266     1  3266  11:36:36 /opt/homebrew/bin/opencode serve --hostname 127.0.0.1 --port 63353 --pure
 ...
50535 50311 50535  00:53 /opt/homebrew/lib/.../opencode.exe serve --hostname 127.0.0.1 --port 59742 --pure
```

Every leftover had **PPID 1**: orphaned, owned by nobody. The single running app
had exactly one child. So the app was not starting several servers per launch —
each launch started one and **never stopped the previous one**, because the app
was not given the chance to:

1. `script/build_and_run.sh` begins with `pkill -x AgenticSidebar`. That is
   SIGTERM, and **AppKit's termination hooks do not run for a signal** —
   `applicationShouldTerminate` is only consulted for a graceful quit. The
   process died instantly, its server kept running, and its MCP children with it.
   Every rebuild in a development session added one more tree.
2. `FoundationOpenCodeProcessHandle.terminate()` killed only the **direct
   child**. The backend spawns a process per configured MCP server, so even a
   graceful quit would have left node/python processes behind.
3. Nothing ever looked for leftovers. There was no record of what had been
   started, so the next launch could not have known what to clean up.

## The fixes

**The tree, not the process** (`OpenCodeProcessTree`, new). Descendants are
enumerated through `libproc` (`proc_listallpids` + `PPID`, since a `pid` alone is
reused and cannot be trusted) and signalled *before* the parent exits — after that
they are re-parented to `launchd` and can no longer be found by walking down.
`terminate()` now asks the tree to stop, refreshes the list once while the root is
still alive, ends the root, and then insists on anything still standing.

**A signal now runs the shutdown** (`AppDelegate`). `SIGTERM` and `SIGINT` are
handled with dispatch sources — a signal *handler* would have to be
async-signal-safe, and awaiting a cleanup is not — and both go through the same
`runShutdown` gate as a quit, with the same three-second deadline. This is what
makes the development script's `pkill` clean up after itself, and the same path
covers a logout or a plain `kill`.

**Leases, and a scan** (`OpenCodeServerLedger`, new). A server records
`{pid, port, executablePath, startedAt}` in `OpenCode/servers/<pid>.json` when it
starts and removes it when it stops. At launch, the app ends any leased server
that is still alive — **after checking its command line**, because pids are
reused — and forgets the lease either way. A second source covers the case where
a lease was never written: any process running with the app's exact argument
shape (including the app's own `--pure` flag) that has been orphaned (`PPID 1`)
cannot belong to a running app, so it is ended too. A server the user started
themselves in a terminal does not match, which is what keeps this from being a
process hunt through someone else's work.

**The relaunch waits** (`script/build_and_run.sh`). After `pkill` it polls until
the app is really gone (up to 10 s) instead of racing the new instance against the
old one's teardown — that race was the other half of how this accumulated.

## Minimality: an off MCP server is no longer started

`tools.<name>_* = false` keeps a server's tools out of the context window, but
OpenCode still **starts** every server it knows about: each one is a node, python
or `uv` process that lives for as long as the backend does. Off servers are now
declared `enabled: false` in the managed configuration, with their definition kept
whole so the entry stays valid (and still overrides the same server in the user's
own `opencode.json`, which the app never edits). The tool silencing stays as
well: it covers a server that only the user's configuration knows about.

Combined with the reaping, the steady state is now: one backend per running app,
one MCP process per *enabled* server, and nothing left behind.

## The agent's todo list

OpenCode keeps a task list per session and exposes it at
`GET /session/:id/todo`; its own TUI renders "To-dos 0/7" from exactly that.
The app now reads it and shows the same checklist above the turn it belongs to.

- `AgentTodo` decodes the backend's list **tolerantly**: an unknown status becomes
  `pending` and a missing id falls back to the text, because a checklist that
  silently drops rows is worse than one that shows a task as still open.
- The list is re-read when the agent writes it — a `todowrite` tool call is
  recognised as its own activity kind (`.todo`), which is both the checklist icon
  in the timeline and the refresh trigger — and once more when a turn ends, since
  the last write and the end of the turn are not the same event.
- Opening a conversation refreshes it too: the list lives with the backend's
  session, so it is read rather than restored from the archive.
- `nil` from a provider means "no such concept" and leaves the last list in place;
  the default protocol implementation returns `nil`, so a provider that has no
  todos (OpenAI) is unaffected.
- The card collapses, counts what is finished (`completed/total` — a cancelled
  task is not progress), and names the task being worked on.

## Checks

```
swift build --product AgenticSidebar -Xswiftc -warnings-as-errors   # clean
swift test -Xswiftc -warnings-as-errors                            # 427 tests, 1 skipped, 0 failures
```

The new tests are the interesting part here: `OpenCodeProcessLifecycleTests`
spawns a real process whose *arguments* have the app's launch shape and asserts
that reaping ends it — and, just as important, that a lease naming a live process
that is **not** a server (`getpid()`) is left alone rather than killed by pid.
`AgentTodoTests` covers decoding, progress, placement and the tool-kind mapping.

# Delegated subagents and the approval level — 2026-09-17

Everything below is a command output from this session unless a line is marked as
an inference. The user's report was two claims at once:

> subagents aren't covered by the permissions AgenticSidebar grants — subagents
> start but stay stuck in the UI.

Both turned out to be true, and they are different problems with different owners.

## 1. The app dropped every request that came from a subagent

Production evidence, OpenCode's own log (`~/.local/share/opencode/log/opencode.log`):

```
08:48:03.625  evaluated permission=task pattern=code-reviewer action.action=ask
08:48:03.626  asking id=per_0ae8d3029001jTBwY5UMGXHpig permission=task patterns=["code-reviewer"]
08:48:03.639  created id=ses_f5172cfc8ffdhBFZ7Gb9r6WuLz parentID=ses_f5173717affexmVzp5NH65DbB3
              agent=code-reviewer mode=subagent
08:48:06.981  evaluated permission=external_directory pattern=/Users/dogan/Desktop/AgenticSidebar/*
              action.permission=* action.action=ask
08:48:06.981  asking id=per_0ae8d3d45001ts7B93uxPSwXEW permission=external_directory
08:48:07.087  asking id=per_0ae8d3daf001jwUQ70ink6wpwu permission=external_directory
08:49:47.092  cancel session.id=ses_f5173717affexmVzp5NH65DbB3
08:49:47.094  cancel session.id=ses_f5172cfc8ffdhBFZ7Gb9r6WuLz
              …error=Aborted
```

The app's audit log for the same window has exactly two records:

```
2026-09-17T08:48:03Z | ses_f5173717af | task | policy | once
2026-09-17T08:48:03Z | ses_f5173717af | started | None | None
```

The parent's `task` request was answered; the child's two `external_directory`
requests at 08:48:06/07 produced **no record at all** — not a decision, not a
timeout, not a cancellation. The subagent sat blocked for 104 seconds and was
aborted with the parent. `GET /permission` is not polled by the app, so a request
that never arrives on the stream is invisible to it.

The cause was a single line: `OpenCodeStreamNormalizer` delivered
`permission.asked` only when the event's `sessionID` matched the session the
subscription was opened for. A subagent's request carries the child's id, so it
was dropped before the approval centre ever saw it. The exemption is now in the
tree (`case "permission.asked"` no longer consults `targetSession`), with the
duplicate-id sharing that makes two arrivals of one request agree.

### Verified against a real server

`script/verify-subagent-permissions.mjs` starts OpenCode with the app's own
arguments (`serve --hostname 127.0.0.1 --port <p> --pure`, `OPENCODE_CONFIG`
pointing at a managed configuration), holds one `/event` subscription the way the
app's client does, and delegates through the real `task` tool:

```
$ node script/verify-subagent-permissions.mjs --agent code-reviewer --verbose
    server ready at http://127.0.0.1:62246
    model opencode-go/deepseek-v4.1-flash
    answering per_0aeb89e1b001… for session ses_f51477841ffeeX75J0JrDWHxjy (external_directory)
    answering per_0aeb8a6bc001… for session ses_f51477841ffeeX75J0JrDWHxjy (task)
    answering per_0aeb8b0f9001… for session ses_f51475748ffefvcJCNmx0OocSw (external_directory)
✓ the parent's own request arrives — 2 request(s)
✓ a subagent's request arrives — 1 request(s) from ses_f51475748ffefvcJCNmx0OocSw
✓ the turn stays open while the subagent waits — no parent idle while a subagent request was waiting
✓ a request the subscription missed is still answerable — nothing stranded
4/4 steps passed
```

Three things that mattered while building the harness, each measured rather than
assumed:

- `POST /session/{id}/shell` is **not** permission-gated — it produced no
  `evaluated`/`asking` line at all — so the harness drives the model instead.
- `bash` is not usable as the trigger: it resolves to `allow` on this machine
  (see §3).
- `XDG_CONFIG_HOME` has to be redirected for the managed configuration to be the
  whole policy; `~/.opencode/opencode.json` is still loaded either way.

## 2. What the app changed

| Change | Why |
| --- | --- |
| `permission.asked` exempt from the session filter | A child session's request is the only signal that will ever arrive for it; dropping it strands the subagent |
| `OpenCodePermissionRequest.isDelegatedSession` (`marked(ownedBy:)`) | The approval card can say *Delegated subagent*; an identical-looking question asked on the agent's behalf is otherwise indistinguishable from the turn's own |
| `PermissionApprovalCenter.rejectAll(remoteSessionID:appSessionID:)` | Stopping a turn left a subagent's prompt on screen — and its waiter unreleased — until the 180 s timeout, because the child's request carries a different remote session id |
| One `skill` member instead of two in the managed configuration | A JSON object cannot hold a key twice; OpenCode kept the last `skill` member, so the app's `skill: "allow"` was discarded and every skill raised a prompt the app then answered itself |

Evidence for the last one, from the app's own configuration file before the fix:

```
permission: { …, "skill": "allow", …, "skill": { "ai-seo": "deny", … } }
```

and the server acting on the second one:

```
09:02:20.555  evaluated permission=skill pattern=using-superpowers action.permission=* action.action=ask
09:02:20.555  asking id=per_0ae9a438b001QGOdm0mnBeU4fH permission=skill patterns=["using-superpowers"]
```

After the fix the file carries exactly one `skill` member,
`{"*": "allow", "<switched-off>": "deny", …}`.

## 3. The part the app cannot fix: the level is not the last word

The user's second claim — "the permissions AgenticSidebar grants don't cover
subagents" — is true in a way that has nothing to do with session filters. The
app's rules decide the requests that **reach the app**, and OpenCode merges other
sources after them.

Measurement, with only the app's configuration in play (a temporary `HOME` so the
machine's own files are absent):

```
$ HOME=/tmp/fakehome-oc XDG_DATA_HOME=/Users/dogan/.local/share node bash-probe.mjs
prompt status: 204
permission requests: bash(echo probe-one)
```

The same probe with the machine's own `~/.opencode/opencode.json` present, whose
`agent.build.tools` enables `read`, `edit`, `bash`, `write` and `changed-files`:

```
resolved agent.build.permission:
  {"read":"allow","edit":"allow","bash":"allow","changed-files":"allow"}
evaluated permission=bash pattern="echo probe-one"
  action.permission=bash action.action=allow action.pattern=*
permission requests: none
```

OpenCode converts an agent's enabled `tools` into agent-level permission rules,
and those come after the configuration. Both string (`"bash": "ask"`) and object
(`"bash": {"*": "ask"}`) forms were measured; neither survives, with or without
`--pure`. Writing the rule at the agent level does not survive either — the app's
`agent.build.permission.bash` was replaced by the tools-derived `allow` in the
resolved configuration. Subagents are the same story: every one of the machine's
subagent definitions carries `tools: {read: true, bash: true}`, which is why their
shell calls never asked.

This matches the production audit exactly: 832 `external_directory` decisions, 21
`task`, 38 `todowrite`, and **no `bash` decision in the whole file**. What the
level governs is the families the agent does not declare — external paths,
`todowrite`, `skill`, `task`, web access, the doom-loop guard, MCP tools and
computer use. Plan mode is unaffected because the app defines that agent with an
explicit `permission` block and no `tools` map.

Recorded as **Round 5** of `TODO_code-reviewer.md`; the remaining work is to say
this inside the app instead of only in this file.

## Verification

- `swift build` / `swift test` under `-warnings-as-errors`: **552 tests, 2 skipped
  (opt-in), 0 failures**. New: the delegation marking, the exemption's own
  delivery test, cancellation covering a conversation's delegated requests, and a
  single-`skill`-member assertion (a duplicate key is invisible to
  `JSONSerialization`, which is why that one counts occurrences in the text).
- `node script/verify-subagent-permissions.mjs`: 4/4, output above.
- The app was rebuilt, installed and started (pid 58902); it has one server
  (pid 58904, leased as `servers/58904.json`) and one MCP child (pid 58906).

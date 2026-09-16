# MCP, plugins and skills — install, tag, and stay out of the context window

2026-09-16

## The problem

Modern IDEs load every configured MCP server and plugin into the model's context
on every request. The tools are described in full whether or not the model ever
calls one, so a user with six servers pays for six servers' worth of schemas on a
one-line question. Nothing in the app decided *what the agent may reach*; the
user's own `opencode.json` decided it, all the time.

The goal here was the opposite arrangement:

- one place to install MCP servers, plugins and skills, with the auth they need;
- skills.sh as a source, not as a separate tool;
- `@` and `/` in the composer to point a turn at what it should use;
- and **nothing loaded just because it exists**.

## What decides context now

The rule is written into the data model rather than into a screen:

| Kind | Cost while installed | Cost when tagged for a turn |
| --- | --- | --- |
| Skill | one line (name + description, via OpenCode's lazy loading) | a line naming it |
| MCP server | its tools' schemas, **only if enabled**; silent otherwise | a line naming it |
| Plugin | nothing by itself | a line naming it |

Three mechanisms keep that promise:

1. **A managed configuration, not an edited one.** The app writes
   `managed-config.json` into its own application-support folder and points
   OpenCode at it with `OPENCODE_CONFIG`. The user's `opencode.json` is never
   touched — `GlobalOpenCodeConfigReader` only reads it.
2. **Silencing by pattern.** A server the user did not enable is written into
   `tools` as `"<name>_*": false`. That is the only way to keep a server that
   lives in the user's own configuration out of the model's context without
   editing their file. A skill switched off becomes `permission.skill.<name> =
   "deny"` — named, never `"*"`, so a stricter rule in the user's own
   configuration still outranks it.
3. **Tags cost lines, not schemas.** `ExtensionTag.turnInstruction` is the whole
   of it: three lines naming what the turn should use and telling it not to reach
   for anything else. Tagged content travels through `QueuedPrompt` →
   `ChatMessage` → `ProviderRequest.extensionContext`, so it is per-turn, and an
   untagged turn adds nothing at all.

## Files

New:

- `Extensions/ExtensionModels.swift` — kinds, sources, MCP/plugin/skill records,
  tags, and the instruction a set of tags produces.
- `Extensions/SkillManifest.swift` — parses and validates `SKILL.md` against the
  rules OpenCode enforces (name, description, body, folder/name agreement).
- `Extensions/ExtensionRegistry.swift` — the app's own book of what exists and
  what is active, plus atomic JSON persistence.
- `Extensions/GlobalOpenCodeConfigReader.swift` — reads (never writes) the
  user's `opencode.json`/`opencode.jsonc`, including a hand-written JSONC
  scanner so `//` inside a URL is not mistaken for a comment.
- `Extensions/ManagedOpenCodeConfiguration.swift` — the single writer of the
  configuration OpenCode loads.
- `Extensions/ExtensionHTTP.swift`, `SkillsShClient.swift`,
  `GitHubSkillFetcher.swift`, `SkillInstaller.swift` — the fetching side:
  skills.sh for discovery, the GitHub tree API to find the folder, raw
  contents to download it, and validation before anything is written.
- `Extensions/SkillsCatalog.swift` — lists the skills OpenCode would see from
  all four of its search roots, *including the ones it would refuse*, with the
  reason.
- `Extensions/ExtensionStore.swift` — the app-facing state: registry, discovery,
  installation, application to the server, and the status line the UI shows.
- `Extensions/ExtensionTrigger.swift` — the `@` / `/` rule, extracted so it can
  be tested without a window.
- `Views/Settings/SettingsExtensionsTab.swift` — the MCP, plugin and skills
  screen.
- `Support/JSONValue.swift` — an order-preserving JSON writer, because
  permission rules are evaluated last-match-wins and dictionaries lose order.

Changed:

- `OpenCodeServerManager` now writes the extension sections into the managed
  configuration and asks the store for the current snapshot each time it starts,
  so an install made while the server was stopped cannot be missed.
- `AgentSessionService.send(...)` / `AgentSession.send(...)` /
  `QueuedPrompt` / `ChatMessage` / `ProviderRequest` carry tags.
- `AgentMode.instructions(speedMode:extensionContext:)` and
  `OpenCodePromptBuilder` place the tagged instruction beside the mode and speed
  instructions in both adapters.
- `ComposerView`: the `@` / `/` panel, the tag chips, and tags on send;
  `SettingsView`: the new tab.
- `OpenCodeClient` gained the OAuth pair (`POST /mcp/{name}/auth` and
  `/mcp/{name}/auth/callback`) so a remote server that needs authorization can
  ask for it from the settings screen.

## How it behaves

- **Add a server**: name + either a command or an https URL. It is stored, marked
  active, and written into the configuration; the screen says plainly that MCP
  and plugins are loaded at startup, so "Restart agent" is one click away.
- **Authorize**: a remote server that asks for OAuth opens its authorization page
  in the browser; the code comes back to the same row. OpenCode holds the token —
  the app never does.
- **Silence something**: switching an MCP server off keeps it in the list with
  that fact stated under it. Nothing is deleted by a toggle.
- **Install a skill**: search skills.sh, or paste `owner/repo` plus the folder
  name. A skill whose manifest OpenCode would reject is refused *before* anything
  is written, and the reason is shown.
- **Tag a turn**: type `@` for MCP servers and plugins, `/` for skills. Choosing
  one turns the typed token into a chip; the chips ride with the message, and the
  transcript keeps them, so a reply's reach is visible afterwards.

## Verification

`Tests/AgenticSidebarTests/ExtensionTests.swift` covers:

- manifest parsing: frontmatter, body, name rules, length limits, folder
  mismatch, and that a rejected skill leaves no folder behind;
- the context gate: which servers are registered, which are silenced, that a
  disabled skill is denied by name, and that only active extensions are offered;
- the rendered configuration: valid JSON, `mcp`/`tools`/`plugin`/`permission`
  content, that `oauth` is *absent* for automatic flows, and that an empty
  snapshot writes nothing but the schema;
- the fetch path against a stub transport: tree lookup, shallowest-folder
  choice, an explicit subpath, missing files, and a full install writing both a
  `SKILL.md` and its extra files;
- `skills.sh` payload decoding, including a malformed one;
- the trigger rule: `@` vs `/`, when a token stops being a trigger, and the range
  it occupies;
- `ExtensionStore`: persistence round-trip, refusal of a server with no target,
  disabling without deleting, a newer registry version being ignored rather than
  fatal, and the snapshot handed to the agent matching the registry.

Not covered, honestly: the panel and chips as rendered pixels, the OAuth round
trip against a live server, and whether a specific third-party MCP server's tools
come back — that needs the server running and a real account.

## Deliberate limits

- MCP servers and plugins apply on the next agent start. A live `POST /mcp` is
  used for authorization, but registering a *new* server mid-session would leave
  the user with a half-updated tool list, so the screen offers a restart instead.
- Inherited servers can be silenced but not deleted: the app does not edit the
  user's configuration.
- A skill's body is never copied into the app's storage; it stays on disk where
  OpenCode reads it.

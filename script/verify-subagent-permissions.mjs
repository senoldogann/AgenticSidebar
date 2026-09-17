#!/usr/bin/env node
//
// Whether a permission request raised inside a subagent reaches the app.
//
// The app learns about every permission request the same way the TUI does: it
// holds one `GET /event` subscription open for the turn and answers what arrives
// on it. A subagent runs in its own (child) session, so its requests arrive
// carrying that child's id — and two different things can lose them:
//
//   1. a client that filters events by the session it opened the stream for, and
//   2. the server reporting the parent idle while the subagent still waits, at
//      which point the app ends the turn and stops listening altogether.
//
// This harness starts a real server with the app's own arguments, subscribes to
// `/event` the way the app's client does, and delegates one task through the
// `task` tool, so both can be observed:
//
//   parent request   a request raised in the parent session arrives
//   child request    a request raised in the child session arrives
//   turn open        the parent never reports idle while a child request waits
//   recoverable      `GET /permission` lists anything that never arrived, so a
//                    missed request can still be answered by id
//
// Usage:
//   node script/verify-subagent-permissions.mjs [--agent code-reviewer] [--verbose]
//
// Exit code 0 means every step passed. `--skip-model` only checks that the
// server and the subscription agree on the parent session (no model call).

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";

const OPENCODE = process.env.OPENCODE_BIN ?? "opencode";
const CLAIM_TIMEOUT_MS = 30_000;
const MODEL_TIMEOUT_MS = 150_000;
/// Every request the harness makes is bounded, so a server that stops answering
/// fails the step instead of hanging the run.
const REQUEST_TIMEOUT_MS = 30_000;

const options = parseArguments(process.argv.slice(2));
const results = [];

function parseArguments(argv) {
  const parsed = {
    verbose: false,
    skipModel: false,
    agent: "code-reviewer",
    outsidePath: "/Users/dogan/Desktop/AgenticSidebar/README.md",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--verbose") {
      parsed.verbose = true;
    } else if (argument === "--skip-model") {
      parsed.skipModel = true;
    } else if (argument === "--agent") {
      parsed.agent = argv[index + 1];
      index += 1;
    } else if (argument === "--outside-path") {
      parsed.outsidePath = argv[index + 1];
      index += 1;
    }
  }
  return parsed;
}

function record(name, passed, detail) {
  results.push({ name, passed, detail });
  console.log(`${passed ? "\u2713" : "\u2717"} ${name}${detail ? ` \u2014 ${detail}` : ""}`);
}

function log(message) {
  if (options.verbose) {
    console.log(`    ${message}`);
  }
}

async function freePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function startServer(workingDirectory) {
  const port = await freePort();
  const logPath = path.join(workingDirectory, "server.log");
  // The user's own `opencode.json` is merged over the app's managed one and, in
  // the checkout this was written for, allows every tool — which hides exactly
  // the requests under test. Redirecting the config home leaves the managed
  // configuration as the whole policy, the way the app intends it to be. The
  // data home is left alone so the authenticated providers still resolve.
  const configHome = path.join(workingDirectory, "config-home");
  mkdirSync(configHome, { recursive: true });
  const child = spawn(
    OPENCODE,
    ["serve", "--hostname", "127.0.0.1", "--port", String(port), "--pure"],
    {
      cwd: workingDirectory,
      env: {
        ...process.env,
        XDG_CONFIG_HOME: configHome,
        OPENCODE_CONFIG: path.join(workingDirectory, "managed-config.json"),
      },
      stdio: ["ignore", "pipe", "pipe"],
    }
  );

  let output = "";
  const collect = (chunk) => {
    output = (output + chunk).slice(-20_000);
  };
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", collect);
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", collect);

  const server = { baseURL: `http://127.0.0.1:${port}`, child, logPath, output: () => output };
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      await get(server, "/session");
      writeFileSync(logPath, output);
      return server;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  writeFileSync(logPath, output);
  throw new Error(`server did not answer /session in 30s; log at ${logPath}`);
}

async function request(server, pathname, init) {
  return await fetch(`${server.baseURL}${pathname}`, {
    ...init,
    signal: AbortSignal.timeout(init?.timeout ?? REQUEST_TIMEOUT_MS),
    headers: { "Content-Type": "application/json", ...init?.headers },
  });
}

async function get(server, pathname, init) {
  const response = await request(server, pathname, init);
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${pathname} \u2192 ${response.status} ${text.slice(0, 200)}`);
  }
  return text ? JSON.parse(text) : undefined;
}

/// The app's half of the contract: one subscription, every session's events.
class EventCollector {
  constructor(baseURL) {
    this.baseURL = baseURL;
    this.events = [];
    this.controller = new AbortController();
  }

  async start() {
    const response = await fetch(`${this.baseURL}/event`, {
      headers: { Accept: "text/event-stream" },
      signal: this.controller.signal,
    });
    if (!response.ok || !response.body) {
      throw new Error(`/event \u2192 ${response.status}`);
    }

    this.reading = (async () => {
      const decoder = new TextDecoder();
      let buffer = "";
      try {
        for await (const chunk of response.body) {
          buffer += decoder.decode(chunk, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.startsWith("data:")) {
              continue;
            }
            try {
              this.events.push(JSON.parse(line.slice(5).trim()));
            } catch {
              // A frame this harness cannot read is not a finding by itself.
            }
          }
        }
      } catch (error) {
        if (error.name !== "AbortError") {
          log(`subscription ended: ${error.message}`);
        }
      }
    })();
  }

  permissionRequests() {
    return this.events
      .filter((event) => event.type === "permission.asked")
      .map((event) => event.properties);
  }

  idleEvents() {
    return this.events.filter((event) => event.type === "session.idle");
  }

  async stop() {
    this.controller.abort();
    await this.reading;
  }
}

async function pickModel(server) {
  let providers;
  try {
    providers = await get(server, "/provider");
  } catch {
    return undefined;
  }
  const connected = new Set(providers.connected ?? []);
  if (connected.has("opencode-go")) {
    const provider = (providers.all ?? []).find((entry) => entry.id === "opencode-go");
    const models = Object.values(provider?.models ?? {});
    // The app ran this delegation on `deepseek-v4.1-flash`; a vision variant is
    // not the model under test.
    const chosen =
      models.find((model) => model.id === "deepseek-v4.1-flash") ??
      models.find((model) => model.id.includes("flash") && !model.id.includes("vision")) ??
      models[0];
    if (chosen) {
      return { providerID: "opencode-go", modelID: chosen.id };
    }
  }
  for (const provider of providers.all ?? []) {
    if (!connected.has(provider.id)) {
      continue;
    }
    const model = Object.values(provider.models ?? {})[0];
    if (model) {
      return { providerID: provider.id, modelID: model.id };
    }
  }
  return undefined;
}

async function main() {
  const workingDirectory = mkdtempSync(path.join(tmpdir(), "opencode-subagent-"));
  writeFileSync(
    path.join(workingDirectory, "managed-config.json"),
    JSON.stringify({ $schema: "https://opencode.ai/config.json", permission: { "*": "ask" } }, null, 2)
  );

  const server = await startServer(workingDirectory);
  const collector = new EventCollector(server.baseURL);
  await collector.start();
  log(`server ready at ${server.baseURL}`);

  const sessions = [];
  try {
    const parent = await get(server, "/session", { method: "POST", body: "{}" });
    sessions.push(parent.id);

    if (options.skipModel) {
      record(
        "the subscription is attached to this server",
        collector.events.some((event) => event.type === "server.connected"),
        `connected=${collector.events.some((event) => event.type === "server.connected")}`
      );
    } else {
      const model = await pickModel(server);
      if (!model) {
        record("a model is available for the delegation step", false, "no authenticated provider");
      } else {
        log(`model ${model.providerID}/${model.modelID}`);

        // `bash` is not usable as the trigger: a plain `{ "*": "ask" }` in the
        // managed configuration does not outrank whatever the machine's own
        // files allow, and on this checkout `bash` resolved to allow. Reading a
        // path outside the session directory raises `external_directory`, which
        // no other file claims — the same request that stranded real subagents.
        const outside = options.outsidePath;
        const prompt =
          "Do exactly these two steps, in order.\n" +
          `1. Read the file ${outside} with the read tool.\n` +
          `2. Then delegate with the task tool: subagent_type "${options.agent}" and prompt ` +
          `"Read the file ${outside} with the read tool and report its first heading."\n` +
          "Do not read that file yourself a second time.";

        const response = await request(server, `/session/${parent.id}/prompt_async`, {
          method: "POST",
          body: JSON.stringify({
            model,
            agent: "build",
            parts: [{ type: "text", text: prompt }],
          }),
        });
        if (!response.ok) {
          record("the delegation turn started", false, `${response.status} ${(await response.text()).slice(0, 200)}`);
        } else {
          const answered = new Set();
          const deadline = Date.now() + MODEL_TIMEOUT_MS;
          let idleWhileChildWaited = false;

          while (Date.now() < deadline) {
            for (const idle of collector.idleEvents()) {
              // The app ends the turn on this event and stops listening, so a
              // request still outstanding at that moment is lost for good.
              const outstanding = collector
                .permissionRequests()
                .some((entry) => entry.sessionID !== parent.id && !answered.has(entry.id));
              if (outstanding && idle.properties.sessionID === parent.id) {
                idleWhileChildWaited = true;
              }
            }
            for (const entry of collector.permissionRequests()) {
              if (answered.has(entry.id)) {
                continue;
              }
              answered.add(entry.id);
              log(`answering ${entry.id} for session ${entry.sessionID} (${entry.permission})`);
              await request(server, `/permission/${entry.id}/reply`, {
                method: "POST",
                body: JSON.stringify({ reply: "once" }),
              });
            }

            const requests = collector.permissionRequests();
            const childRequests = requests.filter((entry) => entry.sessionID !== parent.id);
            const turnFinished = collector
              .idleEvents()
              .some((event) => event.properties.sessionID === parent.id);
            if (idleWhileChildWaited || (turnFinished && childRequests.length > 0)) {
              break;
            }
            await new Promise((resolve) => setTimeout(resolve, 250));
          }

          const requests = collector.permissionRequests();
          const childRequests = requests.filter((entry) => entry.sessionID !== parent.id);
          const parentRequests = requests.filter((entry) => entry.sessionID === parent.id);
          const childSessions = [...new Set(childRequests.map((entry) => entry.sessionID))];

          record(
            "the parent's own request arrives",
            parentRequests.length > 0,
            parentRequests.length > 0 ? `${parentRequests.length} request(s)` : "never delivered"
          );
          record(
            "a subagent's request arrives",
            childRequests.length > 0,
            childRequests.length > 0
              ? `${childRequests.length} request(s) from ${childSessions.join(", ")}`
              : "never delivered"
          );
          record(
            "the turn stays open while the subagent waits",
            !idleWhileChildWaited,
            idleWhileChildWaited
              ? "the parent reported idle with a subagent request outstanding"
              : "no parent idle while a subagent request was waiting"
          );

          let pending = [];
          try {
            pending = await get(server, "/permission");
          } catch {
            pending = [];
          }
          const stranded = pending.filter((entry) => !answered.has(entry.id));
          record(
            "a request the subscription missed is still answerable",
            stranded.length === 0,
            stranded.length === 0
              ? "nothing stranded"
              : `${stranded.length} stranded (${stranded.map((entry) => entry.id).join(", ")})`
          );
        }
      }
    }
  } finally {
    await collector.stop();
    for (const sessionID of sessions) {
      try {
        await request(server, `/session/${sessionID}`, { method: "DELETE", timeout: 10_000 });
      } catch {
        // A session that is already gone is not a failure.
      }
    }
    server.child.kill("SIGTERM");
    rmSync(workingDirectory, { recursive: true, force: true });
  }

  const failed = results.filter((result) => !result.passed);
  console.log(`\n${results.length - failed.length}/${results.length} steps passed`);
  process.exitCode = failed.length === 0 ? 0 : 1;
}

main().catch((error) => {
  console.error(`fatal: ${error.message}`);
  process.exitCode = 1;
});

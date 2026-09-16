#!/usr/bin/env node
//
// End-to-end verification of the computer-use chain, without the app and
// without an agent turn.
//
// The app's own readiness card answers a narrower question: it asks the signed
// helper which macOS grants it holds. This harness answers the whole question
// by driving the same MCP server the app registers, over the same stdio
// protocol, with the same arguments:
//
//   node dist/cli.js stdio --root <temp> --personal-admin --enable-computer-use
//
// and then exercising the real tools:
//
//   tools/list        the server exposes the computer_* tools
//   computer_health   the helper is running and holds every TCC grant
//   session_authority_start  an Admin lease can be minted
//   computer_observe  perception works (accessibility tree of the frontmost app)
//   computer_screenshot  pixels work (proves Screen Recording end to end)
//
// The read tools only inspect; nothing types, clicks or moves the pointer.
//
// Usage:
//   node script/verify-computer-use.mjs [--root <chatgpt-system checkout>] [--verbose]
//
// Exit code 0 means every step passed. A failing step prints the server's own
// error so the report is actionable rather than a bare "it did not work".

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

const DEFAULT_ROOT = path.join(homedir(), "Desktop", "chatgpt-system");
const REQUEST_TIMEOUT_MS = 30_000;

function parseArguments(argv) {
  const options = { root: process.env.CHATGPT_SYSTEM_ROOT ?? DEFAULT_ROOT, verbose: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--root") {
      options.root = argv[index + 1];
      index += 1;
    } else if (argument === "--verbose") {
      options.verbose = true;
    } else if (argument === "--help" || argument === "-h") {
      options.help = true;
    }
  }
  return options;
}

function usage() {
  return [
    "Verify the computer-use chain (MCP server → signed helper → macOS permissions).",
    "",
    "Usage: node script/verify-computer-use.mjs [--root <checkout>] [--verbose]",
    "",
    `Defaults to ${DEFAULT_ROOT} (or $CHATGPT_SYSTEM_ROOT).`,
  ].join("\n");
}

/// The MCP client half of the harness: newline-delimited JSON-RPC over stdio.
class McpClient {
  #child;
  #nextId = 1;
  #pending = new Map();
  #buffer = "";
  #stderr = "";
  #closed;

  constructor(child) {
    this.#child = child;

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => this.#receive(chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      this.#stderr = (this.#stderr + chunk).slice(-8_000);
    });

    this.#closed = new Promise((resolve) => child.once("exit", resolve));
  }

  get stderrTail() {
    return this.#stderr.trim();
  }

  #receive(chunk) {
    this.#buffer += chunk;
    let newline = this.#buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.#buffer.slice(0, newline).trim();
      this.#buffer = this.#buffer.slice(newline + 1);
      if (line.length > 0) {
        this.#dispatch(line);
      }
      newline = this.#buffer.indexOf("\n");
    }
  }

  #dispatch(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id === undefined) {
      return;
    }

    const pending = this.#pending.get(message.id);
    if (!pending) {
      return;
    }
    this.#pending.delete(message.id);
    clearTimeout(pending.timer);
    pending.resolve(message);
  }

  request(method, params) {
    const id = this.#nextId;
    this.#nextId += 1;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`${method} timed out after ${REQUEST_TIMEOUT_MS}ms`));
      }, REQUEST_TIMEOUT_MS);

      this.#pending.set(id, { resolve, timer });
      this.#child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  notify(method, params) {
    this.#child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  /// Reads one JSON payload out of a tool result, wherever the server put it.
  static payload(response) {
    if (response.error) {
      throw new Error(`${response.error.code}: ${response.error.message}`);
    }
    const result = response.result;
    if (!result) {
      throw new Error("the tool returned no result");
    }
    if (result.structuredContent) {
      return result.structuredContent;
    }
    const text = (result.content ?? []).find((part) => part.type === "text")?.text;
    if (!text) {
      throw new Error("the tool returned no structured content");
    }
    return JSON.parse(text);
  }

  async call(name, args) {
    const response = await this.request("tools/call", { name, arguments: args });
    return McpClient.payload(response);
  }

  /// The raw result, for a tool whose interest is its content blocks.
  async callRaw(name, args) {
    const response = await this.request("tools/call", { name, arguments: args });
    if (response.error) {
      throw new Error(`${response.error.code}: ${response.error.message}`);
    }
    return response.result;
  }

  async close() {
    this.#child.stdin.end();
    this.#child.kill("SIGTERM");
    await Promise.race([
      this.#closed,
      new Promise((resolve) => setTimeout(resolve, 5_000)),
    ]);
    if (this.#child.exitCode === null && this.#child.signalCode === null) {
      this.#child.kill("SIGKILL");
    }
  }
}

const results = [];

function record(step, ok, detail) {
  results.push({ step, ok, detail });
  const mark = ok ? "PASS" : "FAIL";
  process.stdout.write(`${mark}  ${step}${detail ? ` — ${detail}` : ""}\n`);
}

function describeError(error) {
  return error instanceof Error ? error.message : String(error);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }

  const cliPath = path.join(options.root, "dist", "cli.js");
  if (!existsSync(cliPath)) {
    process.stderr.write(
      `dist/cli.js was not found at ${cliPath}. Run \`npm run build\` in ${options.root}, or pass --root.\n`,
    );
    return 1;
  }

  const workingRoot = mkdtempSync(path.join(tmpdir(), "verify-computer-use-"));
  const helperPath = path.join(
    homedir(),
    ".chatgpt-system",
    "ChatGPTSystemComputerRuntime.app",
  );

  process.stdout.write(`root:   ${options.root}\n`);
  process.stdout.write(`helper: ${helperPath}\n\n`);

  record(
    "helper installed",
    existsSync(helperPath),
    existsSync(helperPath) ? helperPath : "missing — run `npm run setup:computer:macos`",
  );

  const child = spawn(
    process.execPath,
    [
      cliPath,
      "stdio",
      "--root",
      workingRoot,
      "--personal-admin",
      "--enable-computer-use",
    ],
    {
      cwd: options.root,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, CHATGPT_SYSTEM_MCP_VERIFIER: "1" },
    },
  );

  const client = new McpClient(child);
  if (options.verbose) {
    child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  }

  child.on("exit", (code, signal) => {
    if (code !== 0 && code !== null) {
      process.stderr.write(`\nMCP server exited with code ${code} (signal ${signal ?? "none"})\n`);
      if (client.stderrTail) {
        process.stderr.write(`${client.stderrTail}\n`);
      }
    }
  });

  try {
    // 1. Handshake.
    let initialize;
    try {
      initialize = await client.request("initialize", {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "agentic-sidebar-verify", version: "1.0.0" },
      });
      client.notify("notifications/initialized", {});
      const version = initialize.result?.serverInfo?.version ?? "unknown";
      record("MCP handshake", !initialize.error, `chatgpt-system ${version}`);
    } catch (error) {
      record("MCP handshake", false, describeError(error));
      throw error;
    }

    // 2. The tool surface the app's permission rules are written against.
    const listing = await client.request("tools/list", {});
    const names = (listing.result?.tools ?? []).map((tool) => tool.name);
    const computerTools = names.filter((name) => name.startsWith("computer_"));
    const authorityTools = names.filter((name) => name.startsWith("session_authority_"));
    record(
      "tools/list",
      computerTools.length > 0 && authorityTools.length > 0,
      `${computerTools.length} computer_* and ${authorityTools.length} session_authority_* tools` +
        ` (of ${names.length})`,
    );
    record(
      "computer_run_js is exposed for the app to deny",
      names.includes("computer_run_js"),
      names.includes("computer_run_js")
        ? "present, so the app's deny rule is load-bearing"
        : "absent",
    );

    // 3. The helper's view of macOS.
    //
    // Read this as a protocol probe, not a permission report: tccd answers
    // kTCCServiceScreenCapture for the *responsible* process, so a helper this
    // script started answers with whatever grant this shell has. A green
    // screenRecording here does not mean the app has one — the app's own
    // Settings card is the only place that says.
    const health = await client.call("computer_health", {});
    const grants = {
      accessibility: health.accessibilityTrusted === true,
      screenRecording: health.screenCaptureAuthorized === true,
      inputMonitoring: health.eventListenAuthorized === true,
      eventPosting: health.eventPostAuthorized === true,
    };
    record(
      "computer_health",
      health.state === "running" && Object.values(grants).every(Boolean),
      `state=${health.state} ` +
        Object.entries(grants)
          .map(([name, granted]) => `${name}=${granted}`)
          .join(" "),
    );

    // 4. Authority. A short lease is enough for one reading and expires by itself.
    const lease = await client.call("session_authority_start", {
      profile: "admin",
      requestedTtlSeconds: 120,
    });
    const leaseId = lease.leaseId;
    record("session_authority_start", typeof leaseId === "string" && leaseId.length >= 40, `profile=${lease.profile ?? "admin"}`);

    // 5. Perception: the accessibility tree of whatever is frontmost.
    const observation = await client.call("computer_observe", { authorityLeaseId: leaseId });
    const application = observation.application?.name ?? observation.scope?.application?.name;
    record(
      "computer_observe",
      Boolean(observation) && (observation.perception !== undefined || application !== undefined),
      application ? `frontmost application: ${application}` : "perception payload returned",
    );

    // 6. Pixels: this is the step that proves Screen Recording, not just its
    // flag. A refused capture still answers, with a frame that compresses to
    // almost nothing, so a byte floor is what separates the two.
    const screenshot = await client.callRaw("computer_screenshot", { authorityLeaseId: leaseId });
    const image = (screenshot.content ?? []).find((part) => part.type === "image");
    const bytes = image?.data ? Math.floor((image.data.length * 3) / 4) : 0;
    const width = screenshot.structuredContent?.width;
    const height = screenshot.structuredContent?.height;
    const hasRealFrame = bytes > 10_000 && (width ?? 0) > 0 && (height ?? 0) > 0;
    record(
      "computer_screenshot",
      hasRealFrame,
      `${width}×${height} px, ${Math.round(bytes / 1024)} KiB of PNG`,
    );
  } catch (error) {
    record("remaining steps", false, describeError(error));
  } finally {
    await client.close();
    rmSync(workingRoot, { recursive: true, force: true });
  }

  const failed = results.filter((result) => !result.ok);
  process.stdout.write(
    `\n${results.length - failed.length}/${results.length} steps passed\n`,
  );
  return failed.length === 0 ? 0 : 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error) => {
    process.stderr.write(`${describeError(error)}\n`);
    process.exitCode = 1;
  });

// @ts-nocheck

import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const EXTENSION_PATH = realpathSync(fileURLToPath(import.meta.url));
// The extension lives at <checkout>/agents/pi/agent-state.ts.
const EXTENSION_ROOT = dirname(dirname(dirname(EXTENSION_PATH)));
const STATE_BIN = join(EXTENSION_ROOT, "bin", "agent-state");
const AGENT = "pi";

type State = "working" | "blocked" | "done" | "idle";

function paneId(): string | undefined {
  return process.env.TMUX_PANE || undefined;
}

function runState(args: string[]): Promise<void> {
  if (!paneId()) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    try {
      execFile(STATE_BIN, args, { timeout: 5000 }, () => resolve());
    } catch {
      resolve();
    }
  });
}

let requestQueue: Promise<void> = Promise.resolve();

function send(args: string[]): Promise<void> {
  requestQueue = requestQueue.then(
    () => runState(args),
    () => runState(args),
  );
  return requestQueue;
}

function setState(state: State): void {
  void send(["set", AGENT, state]);
}

export default function (pi) {
  if (!paneId()) {
    return;
  }

  let rootSession = false;
  let blockedByUs = false;

  pi.on("session_start", (_event, ctx) => {
    // Only the root TUI owns the pane. RPC/print sessions and sub-agents must not
    // overwrite the state reported by the visible pi process.
    if (ctx?.mode !== "tui") {
      return;
    }
    rootSession = true;
    blockedByUs = false;
    setState(ctx?.isIdle?.() === false ? "working" : "idle");
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!rootSession) {
      return;
    }
    setState("working");
  });

  pi.on("ui_prompt_start", (_event, ctx) => {
    if (!rootSession || ctx?.isIdle?.() === true) {
      return;
    }
    blockedByUs = true;
    setState("blocked");
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    if (!rootSession || !blockedByUs) {
      return;
    }
    blockedByUs = false;
    setState(ctx?.isIdle?.() === true ? "idle" : "working");
  });

  pi.on("agent_settled", (event, ctx) => {
    if (!rootSession || ctx?.isIdle?.() !== true) {
      return;
    }
    blockedByUs = false;
    setState(event?.aborted === true ? "idle" : "done");
  });

  pi.on("session_shutdown", async () => {
    if (!rootSession) {
      return;
    }
    rootSession = false;
    blockedByUs = false;
    await send(["clear"]);
  });
}

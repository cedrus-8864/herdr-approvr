#!/usr/bin/env bun
//
// Approvr -- herdr plugin
//
// When an agent pane flips to `blocked` (it surfaced a permission / question
// prompt), read the visible prompt, and show a macOS notification with one
// button per numbered option (via `alerter`). Clicking a button sends that
// option's digit back to the pane; clicking the notification body focuses the
// pane instead.
//
// Before sending anything we re-check that the pane is still blocked, so an
// answer given in the terminal while the notification was up is never
// double-submitted.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const herdr = process.env.HERDR_BIN_PATH || "herdr";
const iconPath = join(import.meta.dir, "assets", "herdr.png");
const ALERTER = "alerter";
const NOTIFICATION_TIMEOUT_SECS = "120";
const MAX_BUTTON_LABEL = 40;
const PANE_READ_LINES = "40";

function run(args) {
  const r = spawnSync(herdr, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.status !== 0) {
    throw new Error(`${herdr} ${args.join(" ")} failed: ${(r.stderr || r.stdout || "").trim()}`);
  }
  return r.stdout;
}

function json(args) {
  const out = run(args).trim();
  return out ? JSON.parse(out) : null;
}

// ---------------------------------------------------------------------------
// Prompt parsing
// ---------------------------------------------------------------------------

// Find the bottom-most numbered option list (1. ... 2. ...) in the pane text,
// as rendered by Claude Code and similar agents. Returns null when the visible
// screen holds no such list.
export function parseApproval(text) {
  const lines = text
    .split("\n")
    .map((l) => l.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "").replace(/^[\s│┃|]+|[\s│┃|]+$/g, ""));

  let start = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (/^(?:[❯>]\s*)?1\.\s+\S/.test(lines[i])) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;

  const options = [];
  for (let i = start; i < lines.length; i++) {
    const m = lines[i].match(/^(?:[❯>]\s*)?(\d+)\.\s+(.+)$/);
    if (!m) {
      if (options.length) break; // wrapped label line -> list ended
      continue;
    }
    if (Number(m[1]) !== options.length + 1) break;
    options.push({ digit: m[1], label: m[2].trim() });
  }
  if (options.length < 2) return null;

  // Context above the list: the approval block's content (tool name, command,
  // question). It ends upward at a horizontal rule or at conversation chrome
  // (status spinner, tool output, prompt lines). Long commands are compressed
  // to head + tail -- the head names the tool and command, the tail holds the
  // question.
  let context = [];
  for (let i = start - 1; i >= 0 && context.length < 40; i--) {
    const line = lines[i];
    if (/^[╭╰]?[─━┄┈-]{3,}[╮╯]?$/.test(line)) break;
    if (/^[✻⏺⎿❯✳✽·※]/.test(line)) break;
    if (!line) continue;
    context.unshift(line);
  }
  if (context.length > 7) context = [...context.slice(0, 4), "…", ...context.slice(-2)];
  const question = [...context].reverse().find((l) => /\?$/.test(l)) || "";
  return { question, context, options };
}

// Button labels: alerter's --actions is comma-separated, so commas must go.
function buttonLabel(label) {
  const clean = label.replace(/,/g, ";").replace(/\s+/g, " ").trim();
  return clean.length > MAX_BUTTON_LABEL ? `${[...clean].slice(0, MAX_BUTTON_LABEL - 1).join("")}…` : clean;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

// Bring the terminal app to the front -- `pane focus` only switches panes
// inside herdr. Best effort: activate the first known terminal that is running.
function activateTerminal() {
  const terminals = [
    ["kitty", "kitty"],
    ["ghostty", "Ghostty"],
    ["iTerm2", "iTerm"],
    ["wezterm-gui", "WezTerm"],
    ["alacritty", "Alacritty"],
    ["Terminal", "Terminal"],
  ];
  for (const [proc, app] of terminals) {
    if (spawnSync("pgrep", ["-xq", proc]).status === 0) {
      spawnSync("open", ["-a", app]);
      return;
    }
  }
}

function focusPane(paneId) {
  // `pane focus` is direction-only; `agent focus` accepts a pane id and jumps
  // workspace + tab + pane. Blocked panes are always agent panes.
  run(["agent", "focus", paneId]);
  activateTerminal();
}

function stillBlocked(paneId) {
  try {
    return json(["pane", "get", paneId])?.result?.pane?.agent_status === "blocked";
  } catch {
    return false; // pane gone
  }
}

function main() {
  // Event payload is wrapped: {"event": "...", "data": {pane_id, agent_status, ...}}
  const rawEv = JSON.parse(process.env.HERDR_PLUGIN_EVENT_JSON || "null");
  const ev = rawEv?.data ?? rawEv;
  const ctx = JSON.parse(process.env.HERDR_PLUGIN_CONTEXT_JSON || "null");
  const paneId = ev?.pane_id || ctx?.pane?.pane_id || process.env.HERDR_PANE_ID;
  if (!paneId) return;

  // Event path only fires the notification on the idle/working -> blocked flip;
  // the manual `notify` action skips this gate for testing.
  if (ev && ev.agent_status !== "blocked") return;

  const agent = ev?.display_agent || ev?.agent || ctx?.pane?.agent || "agent";
  const topic = String(ev?.title || "").replace(/[\x00-\x1f\x7f]/g, " ").trim();

  // Title = the tab's label (what the user sees in the tab bar), so the
  // notification says *which* session is asking.
  let heading = "";
  try {
    const pane = json(["pane", "get", paneId])?.result?.pane;
    const tabId = pane?.tab_id;
    heading = (tabId && json(["tab", "get", tabId])?.result?.tab?.label) || pane?.label || "";
  } catch {}

  // "visible" = the current screen -- the approval UI is on it by definition.
  const screen = run(["pane", "read", paneId, "--source", "visible", "--lines", PANE_READ_LINES]);
  const approval = parseApproval(screen);

  const message =
    (approval?.context.length ? approval.context.join("\n") : "") ||
    approval?.question || topic || "Waiting for your answer";

  const args = [
    "--title", "Herdr",
    "--message", message,
    "--timeout", NOTIFICATION_TIMEOUT_SECS,
    "--group", paneId, // replaces a stale notification for the same pane
  ];
  args.push("--subtitle", heading || `${agent} needs input`);
  if (existsSync(iconPath)) args.push("--app-icon", iconPath);
  if (approval) args.push("--actions", approval.options.map((o) => buttonLabel(o.label)).join(","));

  const r = spawnSync(ALERTER, args, { encoding: "utf8" });
  if (r.error) throw new Error(`alerter not found -- install it from https://github.com/vjeantet/alerter`);
  const choice = (r.stdout || "").trim();

  if (!choice || choice === "@TIMEOUT" || choice === "@CLOSED" || choice === "@DISMISSED") return;
  // Body click, or the default "Show" button when we had no actions to offer:
  // both mean "take me there" in macOS terms.
  if (choice === "@CONTENTCLICKED" || choice === "@ACTIONCLICKED") {
    focusPane(paneId);
    return;
  }

  const picked = approval?.options.find((o) => buttonLabel(o.label) === choice);
  if (!picked) return;
  if (!stillBlocked(paneId)) {
    console.log(`skipped: ${paneId} no longer blocked (answered in terminal?)`);
    return;
  }
  run(["pane", "send-keys", paneId, picked.digit]);
  console.log(`answered: sent "${picked.digit}" (${picked.label}) to ${paneId}`);
}

if (import.meta.main) {
  try {
    main();
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}

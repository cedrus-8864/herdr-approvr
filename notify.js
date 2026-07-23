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
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const herdr = process.env.HERDR_BIN_PATH || "herdr";
const iconPath = join(here, "assets", "herdr.png");

// Prefer the bundled .app (built by build-app.sh). A bare alerter binary has no
// notification identity of its own, so macOS files its notifications under
// Terminal and its alert style cannot be set separately in System Settings.
const bundledAlerter = join(here, "assets", "HerdrApprovr.app", "Contents", "MacOS", "HerdrApprovr");
const HAS_BUNDLE = existsSync(bundledAlerter);
const ALERTER = HAS_BUNDLE ? bundledAlerter : "alerter";

// alerter impersonates com.apple.Terminal unless told otherwise, so without
// --sender our notifications inherit Terminal's identity: no entry of our own
// in System Settings, hence no way to set the alert style they need.
const SENDER = "dev.cedrus.herdr-approvr";
const MAX_BUTTON_LABEL = 40;
const PANE_READ_LINES = "40";

const DEFAULTS = {
  timeout: 120,             // seconds the notification waits for a click
  sound: "",                // alerter sound name; "" = silent
  suppress_when_focused: true, // stay quiet if you are already looking at the pane
  notify_done: false,       // also notify (without buttons) when an agent finishes
};

// Flat `key = value` TOML, same shape as the example config. Values are quoted
// strings, bare booleans, or integers.
function loadConfig() {
  const cfg = { ...DEFAULTS };
  const dir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  if (!dir) return cfg;
  let text;
  try {
    text = readFileSync(join(dir, "config.toml"), "utf8");
  } catch {
    return cfg; // no config file -> defaults
  }
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith("[")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    const raw = line.slice(eq + 1).trim();
    if (raw[0] === '"' || raw[0] === "'") {
      const end = raw.indexOf(raw[0], 1);
      cfg[key] = end > 0 ? raw.slice(1, end) : raw.slice(1);
      continue;
    }
    const bare = raw.replace(/\s+#.*$/, "").trim();
    cfg[key] = bare === "true" ? true : bare === "false" ? false : /^-?\d+$/.test(bare) ? parseInt(bare, 10) : bare;
  }
  const t = parseInt(cfg.timeout, 10);
  cfg.timeout = Number.isFinite(t) && t > 0 ? t : DEFAULTS.timeout;
  cfg.suppress_when_focused = cfg.suppress_when_focused !== false;
  cfg.notify_done = cfg.notify_done === true;
  return cfg;
}

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

// herdr can post its own system notification for the same blocked agent, which
// then sits next to ours saying the same thing without buttons. We do not touch
// the user's global config, but an unexplained duplicate is worse than a hint.
function warnIfHerdrAlsoNotifies() {
  const home = process.env.HOME;
  if (!home) return;
  let text;
  try {
    text = readFileSync(join(home, ".config", "herdr", "config.toml"), "utf8");
  } catch {
    return;
  }
  if (/^\s*delivery\s*=\s*["']system["']/m.test(text)) {
    console.log('note: herdr [ui.toast] delivery = "system" also posts a notification for this event; set it to "herdr" to keep only ours');
  }
}

// You are "looking at" the pane when it is the focused pane in herdr *and* the
// terminal is the frontmost app -- then herdr's own in-app toast is enough.
function userIsWatching(pane) {
  if (!pane?.focused) return false;
  const r = spawnSync(
    "osascript",
    ["-e", 'tell application "System Events" to name of first process whose frontmost is true'],
    { encoding: "utf8" },
  );
  const front = (r.stdout || "").trim().toLowerCase();
  if (!front) return false;
  return ["kitty", "ghostty", "iterm", "iterm2", "wezterm", "alacritty", "terminal"].some((t) => front.includes(t));
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
  const cfg = loadConfig();

  // Arriving at the pane answers the notification's question: you are here now.
  // Withdraw it rather than leave a stale prompt on screen for a pane you have
  // already dealt with. Notifications are grouped by pane id, so this only ever
  // removes our own.
  if (process.env.HERDR_PLUGIN_EVENT === "pane.focused") {
    // --sender is as load-bearing here as it is when posting: without it the
    // removal targets Terminal's notification center and silently does nothing.
    const args = ["--remove", paneId];
    if (HAS_BUNDLE) args.push("--sender", SENDER);
    spawnSync(ALERTER, args, { encoding: "utf8" });
    return;
  }

  // Event path fires on the flip to `blocked`, and to `done` when the user opted
  // in; the manual `notify` action skips this gate for testing.
  const isDone = ev?.agent_status === "done";
  if (ev && ev.agent_status !== "blocked" && !(isDone && cfg.notify_done)) return;

  const agent = ev?.display_agent || ev?.agent || ctx?.pane?.agent || "agent";
  const topic = String(ev?.title || "").replace(/[\x00-\x1f\x7f]/g, " ").trim();

  // Title = the tab's label (what the user sees in the tab bar), so the
  // notification says *which* session is asking.
  let heading = "";
  let pane;
  try {
    pane = json(["pane", "get", paneId])?.result?.pane;
    const tabId = pane?.tab_id;
    heading = (tabId && json(["tab", "get", tabId])?.result?.tab?.label) || pane?.label || "";
  } catch {}

  if (cfg.suppress_when_focused && userIsWatching(pane)) {
    console.log(`suppressed: ${paneId} is focused and the terminal is frontmost`);
    return;
  }

  // A finished agent has no prompt to parse and nothing to answer: report the
  // topic and let the click take the user there.
  // "visible" = the current screen -- an approval UI is on it by definition.
  const approval = isDone
    ? null
    : parseApproval(run(["pane", "read", paneId, "--source", "visible", "--lines", PANE_READ_LINES]));

  const message = isDone
    ? topic || "Finished"
    : (approval?.context.length ? approval.context.join("\n") : "") ||
      approval?.question || topic || "Waiting for your answer";

  const args = [
    "--title", "Herdr",
    "--message", message,
    "--timeout", String(cfg.timeout),
    "--group", paneId, // replaces a stale notification for the same pane
  ];
  // A finished agent's message is just its topic, so without this the
  // notification looks identical to a prompt waiting for an answer.
  const state = isDone ? "finished" : "needs input";
  args.push("--subtitle", heading ? (isDone ? `${heading} — finished` : heading) : `${agent} ${state}`);
  if (HAS_BUNDLE) args.push("--sender", SENDER);
  if (existsSync(iconPath)) args.push("--app-icon", iconPath);
  if (cfg.sound) args.push("--sound", cfg.sound);
  if (approval) args.push("--actions", approval.options.map((o) => buttonLabel(o.label)).join(","));

  warnIfHerdrAlsoNotifies();
  const r = spawnSync(ALERTER, args, { encoding: "utf8" });
  if (r.error) throw new Error(`alerter not found -- install it from https://github.com/vjeantet/alerter`);
  const choice = (r.stdout || "").trim();

  // Every exit path logs its outcome -- silence here is indistinguishable from
  // a crash when something goes wrong in the field.
  if (!choice || choice === "@TIMEOUT" || choice === "@CLOSED" || choice === "@DISMISSED") {
    console.log(`dismissed: ${choice || "(no choice)"} for ${paneId}`);
    return;
  }
  // Body click, or the default "Show" button when we had no actions to offer:
  // both mean "take me there" in macOS terms.
  if (choice === "@CONTENTCLICKED" || choice === "@ACTIONCLICKED") {
    focusPane(paneId);
    return;
  }

  const picked = approval?.options.find((o) => buttonLabel(o.label) === choice);
  if (!picked) {
    console.log(`unmatched: alerter returned ${JSON.stringify(choice)} for ${paneId}`);
    return;
  }
  if (!stillBlocked(paneId)) {
    console.log(`skipped: ${paneId} no longer blocked (answered in terminal?)`);
    return;
  }
  run(["pane", "send-keys", paneId, picked.digit]);
  console.log(`answered: sent "${picked.digit}" (${picked.label}) to ${paneId}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}

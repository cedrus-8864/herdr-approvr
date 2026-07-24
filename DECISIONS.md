# Decisions

Append-only log of significant architectural decisions for herdr-prompt-reply.

## 2026-07-23 — Configurable notification subtitle via template

**Context:** herdr names tabs `1`, `2`, `3` by default, so the previous subtitle
(the raw tab label) was a poor identifier of *which* session was asking.

**Decision:** Added a `subtitle_format` config key (flat-TOML, same reader as the
other keys). Default `"{workspace} · {agent}"`. Tokens: `{workspace}`, `{agent}`,
`{topic}`, `{cwd}`, `{tab}` — four of five shared with the sibling
`herdr-autolabel` plugin; the fifth differs (autolabel's `{n}` is the tab's
position number, `{tab}` here is the tab's label).

**Notes / rationale:**
- `{agent}` is presented cased-for-reading (`Claude`, `Codex`, `Hermes`) via a
  small known-name map + capitalize-first fallback (`prettyAgent`). herdr reports
  agent ids lower-case.
- `{workspace}` is resolved lazily (`workspace get`) only when the template asks
  for it, to avoid an extra herdr call on every notification.
- Empty tokens must not strand their separator (`{workspace} · {agent}` with no
  workspace → `Claude`); `applyFormat` trims dangling separator punctuation.
- The finished/needs-input distinction is preserved outside the template:
  ` — finished` is appended on `done` so a completion never looks like a waiting
  prompt. Empty formatted subtitle falls back to `"<Agent> finished|needs input"`.
- Token substitution is plain `replacingOccurrences` over a fixed key set rather
  than a regex-closure, to stay off Swift APIs that couldn't be compile-checked
  off-macOS.

## 2026-07-24 — Finished notifications auto-withdraw; prompts never do

**Context:** Under the Alerts style (required so prompt buttons stay clickable),
every notification sits on screen until interacted with. A finished
notification needs no interaction, so it accumulated as clutter.

**Decision:** `done_dismiss_seconds` (default 10, 0 = keep): after posting a
finished notification, the plugin spawns a detached `--remove <id> --delay N`
child that withdraws it. Prompts are never auto-withdrawn — a permission
question must not evaporate while the agent is still waiting.

**Notes / rationale:**
- Request identifiers split by kind: prompts reuse the pane id (so a newer
  prompt replaces the older), finished notifications get a unique
  `<pane>.done.<ms>` id. This is load-bearing: it makes the delayed remover
  incapable of hitting a prompt that took over the pane inside the delay
  window (verified by test: done posted, prompt posted 0s later, remover fired,
  prompt survived).
- Pane-focus withdrawal now clears by threadIdentifier (= pane id), covering
  both kinds; a fresh prompt also clears stale finished notifications of its
  pane on post.
- The detached child is a bounded exception to "no waiting processes": it
  sleeps N seconds and exits, and never waits on the user.

## 2026-07-24 — Renamed: Approvr → Prompt Reply

**Context:** "Approvr" said who acts, not what happens; "prompt reply" names the
actual capability (answer an agent's prompt from the notification) and is
greppable next to the sibling plugins' plain-english names.

**Decision:** Full identifier sync in one move, while the plugin has no outside
installs to break: repo `herdr-prompt-reply`, plugin id `cedrus.prompt-reply`,
bundle `HerdrPromptReply.app` / `dev.cedrus.herdr-prompt-reply`, log
`~/Library/Logs/HerdrPromptReply.log`. Version bumped to 0.4.0.

**Notes / rationale:**
- Changing the bundle id forfeits the notification authorization and Alerts
  style granted to the old id — a one-time re-grant per machine. Accepted now
  precisely because later (post-marketplace-traction) it would be a breaking
  change for every user.
- Historical ADR entries keep their original wording; only live references were
  renamed.

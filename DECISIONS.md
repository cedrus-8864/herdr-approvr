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

## 2026-07-24 — usernoted delivery constraints reshape the dismiss design

**Context:** Body clicks on finished notifications launched the responder but
the response never arrived. Isolated by A/B on macOS 26.5 to two usernoted
behaviors, neither documented:

1. A notification without a registered category never delivers its
   default-action (body click) response. Prompts always worked because their
   action list came with a category; buttonless notifications did not.
2. While any process of the bundle is alive, the click response is routed to it
   instead of a freshly launched instance. The auto-dismiss sleeper was such a
   process — delegate-less — so clicks inside the dismiss window vanished.

**Decision:** Every notification now registers a category (empty actions
allowed). The finished notification reuses the pane id as request id (replacement
semantics return) and carries a millisecond stamp in userInfo; expiry is a
detached `/bin/sh -c 'sleep N; exec notifier --remove <pane> --stamp <ms>'`, so
the bundle binary never lingers, and removal happens only if the stamp still
matches — which is what keeps the remover off a prompt that took over the pane
inside the window (re-verified by the trap test).

## 2026-07-24 — swift-format as the sole style tool, enforced by an edit hook

**Context:** The repo had no linter, no formatter and no CI — style in
`notifier.swift` was hand-maintained and only conventional. Adding an agent
context file (`CLAUDE.md`) made the gap sharper: written-down conventions that
nothing enforces drift.

**Decision:** Adopted Apple's `swift format` (invoked as `swift format`, shipped
with the Xcode toolchain) as both the linter and the formatter, configured by
`.swift-format` at 4-space indent / 100 columns. A one-time reformat of
`notifier.swift` (185+/109-) brings `swift format lint` to zero findings. A
Claude Code `PostToolUse` hook on `Write|Edit` formats and rebuilds whenever
`notifier.swift` changes, surfacing compile errors at edit time.

**Notes / rationale:**
- One tool, zero new dependencies. SwiftLint and Nick Lockwood's SwiftFormat
  were both rejected: each is a `brew install` with rules that overlap
  `swift format`, and this is a single 775-line file.
- The 4-space indent had to be configured explicitly. At the default 2 spaces
  the file produced 505 `Indentation` findings, which would have reformatted
  the whole file against the established style rather than with it.
- `AllPublicDeclarationsHaveDocumentation` and
  `BeginDocumentationCommentWithOneLineSummary` are off: this is a single-file
  executable with no public API, and its comments are deliberately *why*-prose
  that a one-line-summary rule would fight.
- An unrecognized rule name in `.swift-format` is only a warning — the tool
  ignores it and continues. Config typos fail open, so a rule that looks
  enabled may not be.
- The hook rebuilds but does not run `--self-test`; delivery and click routing
  are unobservable from the build anyway. Full verification stays in the
  `verify` skill, which ends by handing the click test to a human.

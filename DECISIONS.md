# Decisions

Append-only log of significant architectural decisions for herdr-approvr.

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

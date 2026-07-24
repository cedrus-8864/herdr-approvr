# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A herdr plugin: one Swift file (`notifier.swift`) compiled into a macOS `.app`
that posts permission prompts as notifications with real answer buttons.

## Build and verify

```sh
swift format lint notifier.swift                                          # must print nothing
./build-app.sh                                                            # the only build step
assets/HerdrPromptReply.app/Contents/MacOS/HerdrPromptReply --self-test   # parseApproval + applyFormat
./test-gate.sh                                                            # post-gate + pane.focused, via stub herdr
assets/HerdrPromptReply.app/Contents/MacOS/HerdrPromptReply --status      # expect "authorization: 2 ... alertStyle: 2"
assets/HerdrPromptReply.app/Contents/MacOS/HerdrPromptReply --list        # delivered notification ids
./uninstall.sh                                                            # run BEFORE `herdr plugin uninstall`
```

`assets/HerdrPromptReply.app/` is gitignored — a fresh clone has no binary
until `./build-app.sh` runs. There is no CI.

Formatting is Apple's `swift format` (Xcode toolchain, no install needed),
configured by `.swift-format`: 4-space indent, 100 columns. A `PostToolUse`
hook in `.claude/settings.json` formats and rebuilds on every edit to
`notifier.swift`, so compile errors surface immediately — don't reformat by
hand.

`./.claude/test-hook.sh` checks that hook (~30s; it reads the command out of
`settings.json`, so it can't pass against a stale copy). Run it after editing
the hook — not on every change.

Dev install: `herdr plugin link . && herdr server reload-config`. `link` skips
`[[build]]`, so build by hand after linking.

Never claim a notification change works on `--self-test` alone. `--self-test`
only covers `parseApproval` fixtures and the stamp guard; delivery, button
layout and click routing are only observable by posting a real notification
and clicking it. Ask the user to do that. See `.claude/skills/verify/`.

## macOS gotchas — do not "simplify" these

- **The `.app` bundle is mandatory.** `UNUserNotificationCenter` refuses bare
  binaries. Hence the bundle plus the ad-hoc `codesign` in `build-app.sh`.
- **`LSMinimumSystemVersion` is 13.0 because of bare-slash Swift Regex.**
  Change the regex style and that floor changes with it.
- **Every notification registers a category, even with zero actions.** A
  notification with no registered category never delivers its body-click
  response (`usernoted`, macOS 26.5).
- **The auto-dismiss sleeper must stay `/bin/sh -c 'sleep N; exec …'`.** While
  any process of the bundle is alive, click responses route to *it* instead of
  a fresh instance — so the sleeper must not be another instance of the bundle
  binary. It looks like a pointless subshell; it is not.
- **The stamp guard is load-bearing.** Removal only fires when the millisecond
  `--stamp` in `userInfo` still matches, so a delayed remover can't kill a
  newer prompt that took over the pane. Covered by a trap test in `--self-test`.
- **Alerts, not Banner.** The user must set the app to Alerts (*Persistent* on
  newer macOS) in System Settings; a Banner slides away and takes the buttons.
- **Launch Services bootstrap.** macOS won't create the System Settings entry
  when the app is first launched from a terminal-spawned process. Fix is
  `open <plugin-root>/assets/HerdrPromptReply.app` once.
- **Responder stdout goes nowhere.** All click outcomes must be logged to
  `~/Library/Logs/HerdrPromptReply.log`.
- **The responder is launched with a near-empty PATH**, so the absolute herdr
  path is baked into the notification `userInfo` at post time. Don't replace it
  with a bare `herdr` lookup.
- Prefer Swift APIs that compile-check off-macOS. Token substitution uses plain
  `replacingOccurrences` over a fixed key set for this reason, not a regex
  closure.

## Renaming

Renaming the bundle id forfeits notification authorization machine-wide, and
two bundle copies share one authorization (unregistering a dev checkout orphans
the GitHub-managed install). These identifiers must stay in sync: repo
`herdr-prompt-reply`, plugin id `cedrus.prompt-reply`, bundle
`HerdrPromptReply.app` / `dev.cedrus.herdr-prompt-reply`, log
`~/Library/Logs/HerdrPromptReply.log`.

## Config and events

Config is a flat TOML hand-read from the plugin config dir (no TOML library);
keys: `sound`, `suppress_when_focused`, `notify_done`, `done_dismiss_seconds`,
`subtitle_format`. Env vars read: `HERDR_PLUGIN_EVENT_JSON` (the payload is
wrapped — real data is under `.data`), `HERDR_PLUGIN_CONTEXT_JSON`,
`HERDR_PANE_ID`, `HERDR_BIN_PATH`, `HERDR_PLUGIN_CONFIG_DIR`,
`XDG_CONFIG_HOME`.

`build-app.sh` only *warns* when the user's global herdr config has
`[ui.toast] delivery = "system"`. Never rewrite the user's global config from
an install script.

## Repo etiquette

- Conventional Commits; `feat!:` for breaking renames.
- `DECISIONS.md` is **append-only** — never edit or reword past entries, they
  keep their original ("Approvr") wording on purpose. Append a new entry that
  supersedes instead. Format: `## YYYY-MM-DD — Title`, then **Context:**,
  **Decision:**, **Notes / rationale:**.
- Style in `notifier.swift` (beyond what `swift format` enforces):
  unabbreviated local names (`identifier`, `arguments`, `semaphore` — not
  `id`/`args`/`sem`), `// -----` section banners, and *why*-comments on every
  non-obvious macOS behavior.
- Releasing: ADR first, then bump `version` in `herdr-plugin.toml`, commit, tag,
  push. See `.claude/skills/release/`.

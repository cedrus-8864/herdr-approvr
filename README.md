# Approvr

A [herdr](https://herdr.dev) plugin that turns agent permission prompts into
**macOS notifications with real answer buttons**. When Claude Code (or any
agent) blocks on a "Do you want to proceed?" prompt, you get a native
notification listing its options — click one and the answer is typed into the
pane for you. No need to hunt for the right tab.

- Click a **button** → that option's digit is sent to the pane (`pane send-keys`)
- Click the **notification body** → the pane is focused instead
- Answered it in the terminal already? The plugin re-checks the pane is still
  `blocked` before sending, so nothing is ever double-submitted
- One notification per pane (`--group`), replaced when a newer prompt appears
- Landing on the pane withdraws its notification, so answering in the terminal
  never leaves a stale prompt on screen

## Requirements

- macOS
- [bun](https://bun.sh) on `PATH`
- [alerter](https://github.com/vjeantet/alerter) on `PATH` — no Homebrew
  formula; grab the zip from its releases page:

  ```sh
  curl -sL https://github.com/vjeantet/alerter/releases/download/v26.5/alerter-26.5.zip -o /tmp/alerter.zip
  unzip -o /tmp/alerter.zip -d ~/.local/bin && chmod +x ~/.local/bin/alerter
  ```

  (Pinned on purpose: `releases/latest/download/` resolves the *release* but not
  the asset name, so it 404s the moment a new version renames the zip.)

## Install

**1. Install the plugin.**

```sh
herdr plugin install cedrus-8864/herdr-approvr
```

This runs `build-app.sh`, which wraps `alerter` in `assets/HerdrApprovr.app`,
ad-hoc signs it, and registers it with Launch Services. The bundle is not
cosmetic: `alerter` impersonates `com.apple.Terminal` unless told otherwise, so
without it the notifications land under **Terminal**, where their alert style
cannot be set and the buttons disappear with the banner. The plugin passes
`--sender dev.cedrus.herdr-approvr` to claim the bundle instead.

*Local development:* `herdr plugin link` skips build commands, so build by hand:

```sh
git clone https://github.com/cedrus-8864/herdr-approvr
cd herdr-approvr && ./build-app.sh
herdr plugin link . && herdr server reload-config
```

**2. Fix the toast delivery, if the install script tells you to.**

`build-app.sh` reads your herdr config and warns when `[ui.toast]
delivery = "system"` is set — that makes herdr post its own buttonless
notification for the same blocked agent, so you get two. It never edits the
file; that is your call:

```toml
[ui.toast]
delivery = "herdr"    # in-app toast; leave desktop notifications to this plugin
```

```sh
herdr server reload-config
```

Note what `"herdr"` costs you: herdr's system notifications also cover agents
that *finish*, which this plugin ignores by default. Set `notify_done = true` in
the plugin config to take that over too, and the switch loses you nothing.
(Per-class opt-out, so neither side has to reimplement the other, is requested in
[herdr#1791](https://github.com/ogulcancelik/herdr/issues/1791).)

`"off"` also stops the duplicate, but then nothing tells you an agent is blocked
while you are looking at herdr — this plugin deliberately stays quiet in that
case (`suppress_when_focused`).

**3. Set the alert style.** Trigger one notification (block an agent, or run
`herdr plugin action invoke cedrus.approvr.notify` from a blocked pane), then set
**Herdr Approvr** to **Alerts** in System Settings → Notifications. The row only
appears once a notification has been delivered. Left as a Banner, it slides away
after a few seconds and takes the answer buttons with it.

## Uninstall

**1. Undo what the install registered**, while the checkout still exists:

```sh
./uninstall.sh
```

It unregisters the bundle from Launch Services and deletes it. It also prints
the command for removing your plugin config, which herdr leaves behind.

**2. Remove the plugin:**

```sh
herdr plugin uninstall cedrus.approvr
```

Order matters: uninstalling a GitHub-managed plugin deletes the checkout, taking
`uninstall.sh` and the bundle with it — leaving a Launch Services entry pointing
at a path that no longer exists.

Skipping step 1 is not harmful, just untidy: macOS prunes dangling registrations
when it rebuilds its database, and the **Herdr Approvr** row in System Settings
disappears on its own schedule. There is no supported command to delete one
notification entry. herdr has no uninstall hook, which is why this is manual —
tracked in [herdr#1791](https://github.com/ogulcancelik/herdr/issues/1791).

## How it works

1. Subscribes to `pane.agent_status_changed`; acts on the flip to `blocked` —
   herdr sets that exactly when a known approval/question UI is visible in the
   pane — and to `done` when `notify_done` is on.
2. Reads the visible screen (`pane read --source visible`) and parses the
   bottom-most numbered option list (`❯ 1. Yes …`), plus the nearest question
   line above it.
3. Shows the notification via `alerter --actions`. macOS renders about three
   message lines until the notification is expanded, which is why the tool name
   and command come first. The options live behind the **Options ⌄** button
   (each becomes its own row once expanded), next to the default **Show**.
4. Maps the clicked label back to its digit and sends it — after re-checking
   the pane is still blocked.

If no option list can be parsed (unknown prompt style), you still get a plain
notification; clicking it focuses the pane.

It also subscribes to `pane.focused` and withdraws that pane's notification
(`alerter --remove <pane-id>`, matching the `--group` it was posted under). This
covers the common case where you answer in the terminal and the notification is
left behind — the safety check would have refused to send anyway, but a stale
prompt on screen is its own annoyance.

## Testing

```sh
bun test.js                                      # parser self-check
herdr plugin action invoke cedrus.approvr.notify # notification for the focused pane
herdr plugin log list --plugin cedrus.approvr --limit 5
```

## Configuration

Optional. Drop a `config.toml` in the plugin's config dir (find it with
`herdr plugin config-dir cedrus.approvr`); see
[`examples/default-config.toml`](examples/default-config.toml).

| Key | Default | Meaning |
|-----|---------|---------|
| `timeout` | `120` | Seconds the notification waits for a click. |
| `sound` | `""` | alerter sound name (`"Ping"`, `"Glass"`, …); empty is silent. |
| `suppress_when_focused` | `true` | Stay quiet when the pane is focused and the terminal is frontmost. |
| `notify_done` | `false` | Also notify when an agent finishes (no buttons; click jumps to the pane). |

## Limitations (v1)

- Option labels are matched back by text; two options with identical first 40
  characters would collide (not the case in practice).
- `alerter` blocks until the notification is answered, withdrawn, or hits
  `timeout`, so each prompt holds one short-lived process for that long.
- Verified on herdr 0.7.5 / macOS 26.5. Earlier herdr releases have plugin v1
  (0.7.0+) but it is unconfirmed whether they run `[[build]]` commands, and
  without the bundle the notifications quietly fall back to Terminal's identity
  — hence `min_herdr_version = "0.7.5"`.

## Credits

- Notifications are delivered by [alerter](https://github.com/vjeantet/alerter) (MIT).
- `assets/herdr.icns` is the herdr logo, taken from
  [dot/herdr-terminal-notifier](https://github.com/dot/herdr-terminal-notifier);
  `assets/herdr.png` is a PNG render of it.

## License

MIT

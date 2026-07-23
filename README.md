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

## Requirements

- macOS
- [bun](https://bun.sh) on `PATH`
- [alerter](https://github.com/vjeantet/alerter) on `PATH` — no Homebrew
  formula; grab the zip from its releases page:

  ```sh
  curl -sL https://github.com/vjeantet/alerter/releases/latest/download/alerter-26.5.zip -o /tmp/alerter.zip
  unzip -o /tmp/alerter.zip -d ~/.local/bin && chmod +x ~/.local/bin/alerter
  ```

Then build the notification app bundle:

```sh
./build-app.sh
```

This wraps `alerter` in `assets/HerdrApprovr.app` and registers it with Launch
Services. `alerter` impersonates `com.apple.Terminal` unless told otherwise, so
the plugin passes `--sender dev.cedrus.herdr-approvr` to claim that bundle
instead — without it, the notifications land under **Terminal** and you cannot
set their alert style separately.

After the first notification, set **Herdr Approvr** to **Alerts** in System
Settings → Notifications, so the notification waits for you instead of sliding
away after a few seconds.

## Install

```sh
herdr plugin install cedrus-8864/herdr-approvr
```

Local development:

```sh
git clone https://github.com/cedrus-8864/herdr-approvr
herdr plugin link ./herdr-approvr
herdr server reload-config
```

## How it works

1. Subscribes to `pane.agent_status_changed`; acts only on the flip to
   `blocked` — herdr sets that exactly when a known approval/question UI is
   visible in the pane.
2. Reads the visible screen (`pane read --source visible`) and parses the
   bottom-most numbered option list (`❯ 1. Yes …`), plus the nearest question
   line above it.
3. Shows the notification via `alerter --actions`. With more than one option,
   macOS puts them in a dropdown on the button.
4. Maps the clicked label back to its digit and sends it — after re-checking
   the pane is still blocked.

If no option list can be parsed (unknown prompt style), you still get a plain
notification; clicking it focuses the pane.

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

## Limitations (v1)

- Option labels are matched back by text; two options with identical first 40
  characters would collide (not the case in practice).
- `alerter` blocks until click or a 120s timeout; each prompt spawns one
  short-lived process.

## Credits

- Notifications are delivered by [alerter](https://github.com/vjeantet/alerter) (MIT).
- `assets/herdr.icns` is the herdr logo, taken from
  [dot/herdr-terminal-notifier](https://github.com/dot/herdr-terminal-notifier);
  `assets/herdr.png` is a PNG render of it.

## License

MIT

# Approvr

Answer [herdr](https://herdr.dev) agent permission prompts straight from a
macOS notification. When Claude Code (or any agent) stops on a *"Do you want to
proceed?"* prompt, the notification shows its options as buttons — click one
and the answer is typed into the right pane for you.

<p align="center">
  <img src="docs/notification.png" width="560" alt="Notification for a blocked agent, showing the tab label, the command awaiting approval, and the question">
  <br>
  <img src="docs/options.png" width="560" alt="The Options dropdown listing Show, Yes, Yes-and-don't-ask-again, and No">
</p>

- **Click an option** → its digit is typed into the pane, after re-checking the
  pane is still blocked (answering in the terminal never double-submits)
- **Click the body / Show** → jump to the pane, across workspaces, bringing the
  terminal forward
- **Focus the pane yourself** → the notification is withdrawn as stale
- One notification per pane; a newer prompt replaces the older one

## Install

Needs macOS and either [bun](https://bun.sh) or node ≥ 18.

```sh
herdr plugin install cedrus-8864/herdr-approvr
```

The install builds a small `HerdrApprovr.app` wrapper for
[alerter](https://github.com/vjeantet/alerter) (downloaded automatically,
SHA-256 pinned). The wrapper is what gives the notifications their own identity,
icon, and settings entry instead of masquerading as Terminal.

Then, once:

1. Trigger a notification (any permission prompt), and set **Herdr Approvr** to
   **Alerts** in System Settings → Notifications — as a Banner it slides away
   in seconds, taking the buttons with it. The entry appears after the first
   notification.
2. If the install output warns that herdr's `[ui.toast] delivery = "system"` is
   set, switch it to `"herdr"` (see below) — otherwise herdr posts a second,
   buttonless notification for the same event.

<details>
<summary>Local development (plugin link)</summary>

`herdr plugin link` skips build commands, so build the wrapper by hand:

```sh
git clone https://github.com/cedrus-8864/herdr-approvr
cd herdr-approvr && ./build-app.sh
herdr plugin link . && herdr server reload-config
```

</details>

## Configuration

Optional — `config.toml` in `herdr plugin config-dir cedrus.approvr`.

| Key | Default | Meaning |
|-----|---------|---------|
| `timeout` | `120` | Seconds the notification waits for a click. |
| `sound` | `""` | Sound name (`"Ping"`, `"Glass"`, …); empty is silent. |
| `suppress_when_focused` | `true` | Stay quiet when you're already looking at the pane. |
| `notify_done` | `false` | Also notify when an agent finishes (no buttons; click jumps to the pane). |

**Recommended setup** — this plugin covers both notification classes, herdr
keeps the in-app toasts:

```toml
# ~/.config/herdr/config.toml
[ui.toast]
delivery = "herdr"
```

```toml
# <herdr plugin config-dir cedrus.approvr>/config.toml
notify_done = true
sound = "Ping"
```

**Minimal / quiet** — prompts only, no sound, nothing on completion: install
and change nothing.

## Long prompts

About three message lines show until you expand the notification, so the tool
name and command come first and the question last. Long commands are compressed
to head `…` tail:

<p align="center">
  <img src="docs/long-collapsed.png" width="500" alt="Collapsed notification truncating a long git commit command">
  <img src="docs/long-expanded.png" width="500" alt="Expanded notification showing the full compressed command and each option as its own row">
</p>

## How it works

On `pane.agent_status_changed` → `blocked` (herdr sets that exactly when an
approval/question UI is visible), the plugin reads the visible screen, parses
the bottom-most numbered option list and the question above it, and posts the
notification via the bundled alerter. A clicked label is mapped back to its
digit and sent with `pane send-keys` — after re-checking the pane is still
blocked. On `pane.focused`, the pane's notification is withdrawn. Unparseable
prompts still notify; clicking focuses the pane.

## Uninstall

```sh
./uninstall.sh                          # unregister + delete the .app wrapper
herdr plugin uninstall cedrus.approvr
```

In that order — uninstalling removes the checkout, and the script with it.
Skipping the script is untidy but harmless; macOS prunes the leftovers on its
own schedule. Automating this needs an uninstall hook in herdr, tracked in
[herdr#1791](https://github.com/ogulcancelik/herdr/issues/1791).

## Troubleshooting

- **Buttons vanish before you can click** → the notification style is still
  Banners; set **Herdr Approvr** to **Alerts**.
- **Two notifications per prompt** → herdr's own system toast is on; set
  `[ui.toast] delivery = "herdr"`.
- **Notification shows under "Terminal"** → the app wrapper is missing; run
  `./build-app.sh` from the plugin directory.
- Every outcome is logged:
  `herdr plugin log list --plugin cedrus.approvr --limit 5`.

## Credits

[alerter](https://github.com/vjeantet/alerter) (MIT) delivers the
notifications. The herdr logo comes from
[dot/herdr-terminal-notifier](https://github.com/dot/herdr-terminal-notifier).

## License

MIT

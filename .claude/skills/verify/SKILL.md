---
name: verify
description: Build and check the Prompt Reply plugin end to end - build-app.sh, --self-test, --status - then hand off the one check only a human can do. Use before claiming any notifier.swift change works.
---

Run these in order from the repo root. Stop at the first failure and report it
verbatim — do not continue, do not summarize a failure as a warning.

1. `swift format lint notifier.swift`
   Must print nothing. Fix with `swift format --in-place notifier.swift`.
   Config is `.swift-format` (4-space indent, 100 columns).

2. `./build-app.sh`
   Must end with `built …/HerdrPromptReply.app`. A note about
   `[ui.toast] delivery = "system"` is informational, not a failure.

3. `assets/HerdrPromptReply.app/Contents/MacOS/HerdrPromptReply --self-test`
   Exits non-zero on failure. Covers `parseApproval` fixtures and the stamp
   guard only.

   Then `./test-gate.sh` — drives `handle-event` through a stub herdr and
   asserts which agent statuses post (blocked / done+notify_done) versus stay
   silent (idle / done), plus that `pane.focused` withdraws. Needs no live
   herdr and touches no real pane. This is what makes the "blocked posts a
   notification with buttons" path a regression check rather than a manual one.

4. `assets/HerdrPromptReply.app/Contents/MacOS/HerdrPromptReply --status`
   Expect `authorization: 2` and `alertStyle: 2`.
   - `authorization` not 2 → the app was never granted notifications. Tell the
     user to run `open assets/HerdrPromptReply.app` once, then approve the
     prompt.
   - `alertStyle` not 2 → it's set to Banner/Temporary, so notifications slide
     away and take the answer buttons with them. Tell the user to set
     **Herdr Prompt Reply** to **Alerts** (*Persistent* on newer macOS) in
     System Settings → Notifications.

5. Decide whether a live click test is actually needed, and say which.

   Two things make the naive live test useless, so check both before asking the
   user for anything:

   - **herdr probably isn't running this checkout.** Check whose binary answers:
     `grep 'responder: launched' ~/Library/Logs/HerdrPromptReply.log | tail -1`.
     A path under `~/.config/herdr/plugins/github/…` means clicks exercise the
     installed copy, not your build. Do **not** run `herdr plugin link .` to
     work around this: two bundle copies share one authorization, and
     unregistering a dev checkout orphans the installed copy's authorization —
     it breaks the user's working setup. Ask first.
   - **`notify` posts nothing unless the pane is `blocked`** (`notifier.swift`,
     the early `return` in the post path — `done` also needs `notify_done`).
     Invoking the action on an idle pane logs nothing and delivers nothing, so
     an empty log is not evidence of a bug.

   If the change is whitespace-only, prefer proving behavior-neutrality
   statically over a live test — it's cheaper and doesn't touch the user's
   install. `swift format` works on the parsed AST, so the only thing that can
   change a value is a string literal:
   - single-line: extract `"…"` from `git show HEAD:notifier.swift` and from the
     working copy, sort both, diff. Must be identical.
   - multiline: Swift strips the *closing* `"""`'s indentation from every line,
     so compare de-indented block bodies, not raw lines. A uniform shift of
     content **and** closing delimiter leaves the value unchanged.

   Otherwise, for real behavior changes, hand off: ask the user to let a pane
   actually block on a permission prompt, click the notification, then check
   `tail -20 ~/Library/Logs/HerdrPromptReply.log` for the `respond:` line.

Report: pass/fail per step. If step 5 ended in a live-test handoff, say plainly
that it is outstanding until the user confirms the click. If it ended in a
static proof, state what was compared. Never report a notification-behavior
change as verified on steps 1–4 alone.

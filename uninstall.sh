#!/bin/sh
# Undo what build-app.sh registered with the system. Run this BEFORE
# `herdr plugin uninstall cedrus.approvr`, because uninstalling a
# GitHub-managed plugin deletes this checkout along with the bundle.
#
# herdr has no uninstall hook, so this cannot run automatically.
set -eu

root=$(cd "$(dirname "$0")" && pwd)
app="$root/assets/HerdrApprovr.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -d "$app" ]; then
  "$lsregister" -u "$app" 2>/dev/null || true
  rm -rf "$app"
  echo "removed $app"
else
  echo "no bundle to remove"
fi

cat <<'EOF'

Two things this script cannot do for you:

  * The "Herdr Approvr" row in System Settings > Notifications outlives the
    bundle. macOS prunes it on its own schedule; there is no supported command
    to delete one entry.
  * Your plugin config still exists. Remove it with:
      rm -rf "$(herdr plugin config-dir cedrus.approvr)"
    (run it before uninstalling the plugin, while the id still resolves)

If ANOTHER copy of HerdrApprovr.app exists (e.g. a GitHub-managed install next
to this dev checkout), unregistering this one can orphan the notification
authorization both copies share. Re-register the surviving copy:
  lsregister -f <path-to-other>/assets/HerdrApprovr.app
(or just run its build-app.sh again).
EOF

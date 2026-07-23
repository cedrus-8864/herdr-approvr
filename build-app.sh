#!/bin/sh
# Wrap the `alerter` binary in an .app bundle so macOS gives our notifications
# their own identity: a "Herdr Approvr" entry in System Settings > Notifications
# (set it to Alerts so the buttons stay on screen), the herdr icon, and no
# borrowing of Terminal's notification settings.
#
# Usage: ./build-app.sh [path-to-alerter]      (default: whatever is on PATH)
set -eu

root=$(cd "$(dirname "$0")" && pwd)
app="$root/assets/HerdrApprovr.app"
alerter=${1:-$(command -v alerter || true)}

# Pinned alerter release, downloaded when none is on PATH. The checksum pins the
# exact binary we tested; a new release must be re-verified, not just re-pointed.
ALERTER_URL="https://github.com/vjeantet/alerter/releases/download/v26.5/alerter-26.5.zip"
ALERTER_SHA256="11f63cddc9bb3f8554ed9b762632a120cfa7bee05e3c09d65734823e09d24f10"

if [ -z "$alerter" ] || [ ! -x "$alerter" ]; then
  echo "alerter not on PATH; downloading pinned release..."
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$ALERTER_URL" -o "$tmp/alerter.zip"
  echo "$ALERTER_SHA256  $tmp/alerter.zip" | shasum -a 256 -c - >/dev/null || {
    echo "alerter download failed checksum verification -- aborting" >&2
    exit 1
  }
  unzip -oq "$tmp/alerter.zip" -d "$tmp"
  alerter="$tmp/alerter"
  chmod +x "$alerter"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$alerter" "$app/Contents/MacOS/HerdrApprovr"
chmod +x "$app/Contents/MacOS/HerdrApprovr"

# The icon must be .icns for the bundle; alerter's --app-icon still works for
# the per-notification image.
if [ -f "$root/assets/herdr.icns" ]; then
  cp "$root/assets/herdr.icns" "$app/Contents/Resources/HerdrApprovr.icns"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>HerdrApprovr</string>
  <key>CFBundleIdentifier</key><string>dev.cedrus.herdr-approvr</string>
  <key>CFBundleName</key><string>Herdr Approvr</string>
  <key>CFBundleDisplayName</key><string>Herdr Approvr</string>
  <key>CFBundleIconFile</key><string>HerdrApprovr</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.14</string>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats the bundle as a stable notification client
# instead of rejecting the modified binary.
codesign --force --deep --sign - "$app" 2>/dev/null || true

# Register with Launch Services so it shows up in System Settings.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$app" 2>/dev/null || true

echo "built $app"

# herdr can post its own (buttonless) system notification for the same blocked
# agent. We only report it -- rewriting the user's global config from an
# install script would be a surprise they never agreed to.
herdr_config="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
if [ -f "$herdr_config" ] && grep -qE '^[[:space:]]*delivery[[:space:]]*=[[:space:]]*"system"' "$herdr_config"; then
  cat <<EOF

NOTE: $herdr_config has [ui.toast] delivery = "system", so herdr posts its own
notification for every blocked agent. Alongside this plugin you will get two,
and herdr's has no answer buttons. To keep the in-app toast and leave desktop
notifications to this plugin:

    [ui.toast]
    delivery = "herdr"

then: herdr server reload-config
EOF
fi

cat <<'EOF'

NEXT: trigger one notification, then set "Herdr Approvr" to Alerts in
System Settings > Notifications. As a Banner it slides away in seconds and
takes the answer buttons with it.
EOF

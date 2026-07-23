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

if [ -z "$alerter" ] || [ ! -x "$alerter" ]; then
  echo "alerter not found. Install it first: https://github.com/vjeantet/alerter" >&2
  exit 1
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

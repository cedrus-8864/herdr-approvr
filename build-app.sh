#!/bin/sh
# Compile the Swift notifier into an .app bundle so macOS gives our
# notifications their own identity: a "Herdr Approvr" entry in System Settings >
# Notifications (set it to Alerts so the buttons stay on screen), the herdr
# icon, and no borrowing of Terminal's notification settings.
#
# UNUserNotificationCenter only works from inside a bundle, so the bundle is a
# hard requirement, not branding.
set -eu

root=$(cd "$(dirname "$0")" && pwd)
app="$root/assets/HerdrApprovr.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found -- install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -enable-bare-slash-regex "$root/notifier.swift" -o "$app/Contents/MacOS/HerdrApprovr"

# The icon must be .icns for the bundle.
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

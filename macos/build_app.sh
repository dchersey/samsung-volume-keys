#!/bin/bash
# Build the SwiftUI menu-bar app into a no-Dock-icon agent .app bundle, sign it
# with a stable identity (so the Accessibility/TCC grant survives rebuilds), and
# install it to /Applications.
#
#   ./macos/build_app.sh           # build, sign, install to /Applications, open
#   ./macos/build_app.sh --here    # build + sign in place, don't install
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/MenuBar"

echo "Building (release)…"
swift build -c release

app="$here/G8Volume.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/release/G8Volume" "$app/Contents/MacOS/G8Volume"

# Bundle the daemon INSIDE the app, so the app spawns it as a child and macOS
# attributes its Local Network access to this signed app (not the churning Python
# binary). The venv/token/cache live in ~/Library/Application Support/g8-volume.
repo="$(cd "$here/.." && pwd)"
mkdir -p "$app/Contents/Resources/daemon"
cp "$repo/g8_volume_bridge.py" "$repo/requirements.txt" "$repo/boot.sh" \
   "$app/Contents/Resources/daemon/"
chmod +x "$app/Contents/Resources/daemon/boot.sh"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>G8 Volume</string>
  <key>CFBundleDisplayName</key><string>G8 Volume</string>
  <key>CFBundleIdentifier</key><string>org.hersey.g8volume</string>
  <key>CFBundleExecutable</key><string>G8Volume</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Code-sign with a stable identity so macOS keeps the Accessibility grant across
# rebuilds (unsigned/ad-hoc rebuilds silently lose TCC trust). Override via
# SIGN_IDENTITY; set it to empty string to skip signing.
SIGN_IDENTITY="${SIGN_IDENTITY-Apple Development: David Hersey (CUACYBN73G)}"
if [ -n "$SIGN_IDENTITY" ]; then
  if codesign --force --deep --sign "$SIGN_IDENTITY" "$app" 2>/dev/null; then
    echo "Signed with: $SIGN_IDENTITY"
  else
    echo "WARN: codesign failed for '$SIGN_IDENTITY' — app is unsigned (Accessibility grant won't persist)."
  fi
fi

echo "Built $app"

if [ "${1:-}" != "--here" ]; then
  dest="/Applications/G8 Volume.app"
  killall G8Volume 2>/dev/null || true
  rm -rf "$dest"
  cp -R "$app" "$dest"
  echo "Installed → $dest"
  open "$dest" || true
else
  echo "Run:  open \"$app\""
fi

echo
echo "First launch: grant Accessibility to \"G8 Volume\" in"
echo "  System Settings → Privacy & Security → Accessibility"
echo "(the volume-key tap is inert without it)."

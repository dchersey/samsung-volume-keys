#!/bin/bash
# Installer for the Mac → Odyssey G8 volume bridge.
#
# Prebuilt (no Xcode), downloads the signed & notarized app:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/samsung-volume-keys/main/install.sh)"
#
# From a source checkout (builds + signs the app locally):
#   ./install.sh
#
# The daemon ships INSIDE the app and is spawned as its child, so macOS attributes
# the daemon's Local Network access to the signed app (the grant then survives Python
# upgrades). There is no LaunchAgent — the app, which launches at login, owns it.
set -euo pipefail

REPO_SLUG="dchersey/samsung-volume-keys"
APP_DEST="/Applications/G8 Volume.app"
LEGACY_LABEL="org.hersey.g8-volume"

say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }
[ "$(uname -s)" = "Darwin" ] || die "macOS only."

# Source checkout (with the Swift toolchain) → build; else download the notarized app.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/macos/build_app.sh" ] \
   && command -v swift >/dev/null 2>&1 && [ "${DOWNLOAD_APP:-0}" != "1" ]; then
  say "Building + installing the menu-bar app (daemon bundled inside)…"
  /bin/bash "$SELF_DIR/macos/build_app.sh"       # builds, signs, installs to /Applications, opens
else
  say "Downloading the signed app…"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/$REPO_SLUG/releases/latest/download/G8Volume.zip" -o "$tmp/app.zip" \
    || die "Couldn't download the app release — is one published yet? (Or run from a checkout to build it.)"
  ditto -x -k "$tmp/app.zip" "$tmp/app"
  src="$(/usr/bin/find "$tmp/app" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$src" ] || die "Release archive contained no .app."
  killall G8Volume 2>/dev/null || true
  rm -rf "$APP_DEST"; ditto "$src" "$APP_DEST"
  open "$APP_DEST" || true
  say "Installed → $APP_DEST"
fi

# Retire the old LaunchAgent daemon — the app owns the daemon process now.
say "Removing any legacy daemon LaunchAgent…"
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

cat <<'DONE'

✅ Installed. The app runs the daemon for you (the first launch builds its Python
venv, ~15s). Four one-time macOS grants — the app's HUD/menu point you at each:

  • Accessibility    → enable "G8 Volume"  (Settings ▸ Privacy & Security ▸ Accessibility)
  • Input Monitoring → enable "G8 Volume"  (… ▸ Input Monitoring)
  • Local Network    → enable "G8 Volume"  (… ▸ Local Network)
  • Pair the monitor: with the G8 as your audio output, press a volume key and accept
    the "Allow this device?" dialog on the monitor once.

Health check:  curl -s 127.0.0.1:8765/status
Daemon log:    ~/Library/Logs/g8-volume.log
DONE

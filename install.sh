#!/bin/bash
# Installer for the Mac → Odyssey G8 volume bridge.
#
# Prebuilt (no Xcode), downloads the signed app + daemon:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/samsung-volume-keys/main/install.sh)"
#
# From a source checkout (builds + signs the app locally):
#   ./install.sh
set -euo pipefail

REPO_SLUG="dchersey/samsung-volume-keys"
RAW="https://raw.githubusercontent.com/$REPO_SLUG/main"
LABEL="org.hersey.g8-volume"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/g8-volume.log"
APP_DEST="/Applications/G8 Volume.app"

say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }
[ "$(uname -s)" = "Darwin" ] || die "macOS only."

# Source checkout (script sits next to the daemon) vs. piped download.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/g8_volume_bridge.py" ]; then
  MODE="source"; HOME_DIR="$SELF_DIR"
else
  MODE="download"; HOME_DIR="$HOME/Library/Application Support/g8-volume"
fi
mkdir -p "$HOME_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# 1. Daemon files (download mode fetches them; source mode already has them) --
if [ "$MODE" = "download" ]; then
  say "Downloading the daemon…"
  curl -fsSL "$RAW/g8_volume_bridge.py" -o "$HOME_DIR/g8_volume_bridge.py"
  curl -fsSL "$RAW/requirements.txt"    -o "$HOME_DIR/requirements.txt"
fi

# 2. Python venv (a real CPython — NOT the pyenv shim, which launchd can't use) --
say "Setting up the Python venv…"
PYBIN="${PYBIN:-/opt/homebrew/bin/python3.13}"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3.13 || command -v python3 || true)"
[ -n "$PYBIN" ] || die "No python3 found. Install one (e.g. 'brew install python')."
"$PYBIN" -m venv "$HOME_DIR/.venv"
"$HOME_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$HOME_DIR/.venv/bin/pip" install --quiet -r "$HOME_DIR/requirements.txt"

# 3. Menu-bar app: build from source if we can, else download the notarized app --
if [ "$MODE" = "source" ] && command -v swift >/dev/null 2>&1 && [ "${DOWNLOAD_APP:-0}" != "1" ]; then
  say "Building + installing the menu-bar app…"
  /bin/bash "$HOME_DIR/macos/build_app.sh"
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

# 4. Daemon LaunchAgent ------------------------------------------------------
say "Installing + loading the daemon LaunchAgent…"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME_DIR/.venv/bin/python3</string>
    <string>$HOME_DIR/g8_volume_bridge.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

cat <<DONE

✅ Installed. Two one-time manual steps macOS requires:

  1) Grant permissions:  System Settings → Privacy & Security
       • Accessibility   → enable "G8 Volume"
       • Input Monitoring → enable "G8 Volume"
     then relaunch the app. Both are required for the volume-key tap.

  2) Pair with the monitor:  with the G8 as your audio output, press a volume key.
     The monitor pops "Allow this device?" — accept it once with the G8 remote.
     The token is saved to ~/.config/g8-volume/token.txt and reused forever after.

Then: with the G8 as output, the volume keys drive the monitor (and soundbar over
ARC) with a relative on-screen HUD. Switch to another output and they behave
natively again.

Health check:  curl -s 127.0.0.1:8765/status
Daemon log:    $LOG
DONE

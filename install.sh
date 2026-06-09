#!/bin/bash
# One-shot installer for the Mac → Odyssey G8 volume bridge.
#   1. Python venv + samsungtvws
#   2. load the daemon LaunchAgent
#   3. build + sign + install the menu-bar app
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd -P)"
cd "$REPO"

# Pick a real CPython for the venv (NOT the pyenv shim, which launchd can't use).
PYBIN="${PYBIN:-/opt/homebrew/bin/python3.13}"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3.13 || command -v python3)"

echo "▸ Creating venv with $PYBIN…"
"$PYBIN" -m venv "$REPO/.venv"
"$REPO/.venv/bin/pip" install --quiet --upgrade pip
"$REPO/.venv/bin/pip" install --quiet -r "$REPO/requirements.txt"

echo "▸ Installing + loading the daemon LaunchAgent…"
/bin/bash "$REPO/priv/launchd/install.sh"

echo "▸ Building + installing the menu-bar app…"
/bin/bash "$REPO/macos/build_app.sh"

cat <<'DONE'

✅ Installed. Two one-time manual steps macOS requires:

  1) Grant Accessibility:  System Settings → Privacy & Security → Accessibility
     → enable "G8 Volume"  (the volume-key tap is inert without it).

  2) Pair with the monitor:  with the G8 as your audio output, press a volume key.
     The monitor pops "Allow this device?" — accept it once with the G8 remote.
     The token is saved to ~/.config/g8-volume/token.txt and reused forever after.

Then: with the G8 as output, the volume keys drive the monitor (and soundbar over
ARC) and show the on-screen level HUD. Switch to another output and the keys behave
natively again.

Health check:  curl -s 127.0.0.1:8765/status
Daemon log:    ~/Library/Logs/g8-volume.log
DONE

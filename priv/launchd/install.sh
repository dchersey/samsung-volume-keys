#!/bin/bash
# Install/reinstall the G8 volume bridge daemon as a per-user LaunchAgent.
#
#   ./priv/launchd/install.sh            # install + load
#   ./priv/launchd/install.sh uninstall  # unload + remove
set -euo pipefail

LABEL="org.hersey.g8-volume"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"

if [ "${1:-}" = "uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled $LABEL"
  exit 0
fi

PY="$REPO/.venv/bin/python3"
SCRIPT="$REPO/g8_volume_bridge.py"
[ -x "$PY" ] || { echo "ERROR: venv python not found at $PY — run the top-level install.sh first." >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "ERROR: daemon not found at $SCRIPT" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

sed -e "s|@PY@|$PY|g" \
    -e "s|@SCRIPT@|$SCRIPT|g" \
    -e "s|@HOME@|$HOME|g" \
    "$REPO/priv/launchd/$LABEL.plist.template" > "$PLIST"
echo "Wrote $PLIST"

# Reload cleanly (modern launchctl: bootout then bootstrap + enable).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Loaded $LABEL. Check: curl -s 127.0.0.1:8765/status ; log: ~/Library/Logs/g8-volume.log"

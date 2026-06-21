#!/bin/bash
# LaunchAgent entry point: self-heal the venv, then exec the daemon.
#
# A Homebrew Python upgrade can remove the interpreter the venv was built against
# (e.g. python@3.13 → 3.14 deletes /opt/homebrew/opt/python@3.13), which leaves the
# venv's python symlink dangling and bricks the daemon with launchd EX_CONFIG. So
# before launching, verify the venv's python imports samsungtvws; if not, rebuild
# the venv from whatever python3 is currently installed. This makes the bridge
# survive `brew upgrade` / `topgrade` instead of needing a manual reinstall.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
VENV="$DIR/.venv"
PY="$VENV/bin/python3"
REQ="$DIR/requirements.txt"
LOG="$HOME/Library/Logs/g8-volume.log"
# launchd's PATH is minimal and excludes Homebrew; make brew's python discoverable.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { printf '%s boot.sh: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

if ! "$PY" -c 'import samsungtvws' >/dev/null 2>&1; then
  log "venv python/deps unusable — rebuilding (likely a Homebrew Python upgrade)"
  # Pick a real CPython, newest first; explicit paths since PATH may be minimal.
  BASE=""
  for c in /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 \
           /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] && BASE="$c" && break
  done
  [ -n "$BASE" ] || { log "FATAL: no python3 found to rebuild the venv"; exit 78; }
  rm -rf "$VENV"
  "$BASE" -m venv "$VENV"
  "$PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  "$PY" -m pip install --quiet -r "$REQ"
  log "venv rebuilt with $BASE ($("$PY" --version 2>&1))"
  # A fresh Python binary loses its macOS Local Network grant — the app's HUD will
  # prompt to re-allow "Python" in Settings ▸ Privacy & Security ▸ Local Network.
  log "NOTE: if keys stop reaching the monitor, re-allow Python in Local Network settings"
fi

exec "$PY" "$DIR/g8_volume_bridge.py"

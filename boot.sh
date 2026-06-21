#!/bin/bash
# Daemon entry point: self-heal the venv, then exec the daemon.
#
# Spawned as a CHILD of the signed "G8 Volume" app (not a LaunchAgent), so macOS
# attributes the daemon's Local Network access to the app's stable signature — the
# grant then survives Python upgrades instead of resetting with each new venv binary.
#
# This script may live read-only inside the app bundle, so the venv + state go in a
# writable home, while the daemon script/requirements load from this script's dir.
#
# A Homebrew Python upgrade can remove the interpreter the venv was built against
# (e.g. python@3.13 → 3.14), which would otherwise brick the daemon; rebuild it then.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"   # daemon script + requirements
HOME_DIR="$HOME/Library/Application Support/g8-volume"        # writable: venv, token, ip cache
VENV="$HOME_DIR/.venv"
PY="$VENV/bin/python3"
SCRIPT="$DIR/g8_volume_bridge.py"
REQ="$DIR/requirements.txt"
LOG="$HOME/Library/Logs/g8-volume.log"
# launchd/app give a minimal PATH; make Homebrew's python discoverable.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$HOME_DIR"
log() { printf '%s boot.sh: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

if ! "$PY" -c 'import samsungtvws' >/dev/null 2>&1; then
  log "venv python/deps unusable — building (new install or a Homebrew Python upgrade)"
  BASE=""
  for c in /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 \
           /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] && BASE="$c" && break
  done
  [ -n "$BASE" ] || { log "FATAL: no python3 found to build the venv"; exit 78; }
  rm -rf "$VENV"
  "$BASE" -m venv "$VENV"
  "$PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  "$PY" -m pip install --quiet -r "$REQ"
  log "venv built with $BASE ($("$PY" --version 2>&1))"
fi

exec "$PY" "$SCRIPT"

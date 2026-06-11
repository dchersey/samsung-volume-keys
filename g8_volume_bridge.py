#!/usr/bin/env python3
"""
g8_volume_bridge.py
-------------------
An always-on local bridge that turns HTTP pings into Samsung remote-control key
events, so the Mac's keyboard volume keys can drive the Odyssey G8 — which in
turn drives the soundbar over ARC.

    G8 Volume.app  ->  http://127.0.0.1:8765/up|down|mute  ->  KEY_VOLUP|VOLDOWN|MUTE

Why a daemon (not a script per keypress): it holds ONE persistent WebSocket to
the monitor, so rapid key-repeats stay smooth. samsungtvws also handles the
token pairing and the self-signed TLS on port 8002.

Two extras over a bare key relay:
  * IP self-healing — discover_tv() finds the monitor by its known WiFi MAC if the
    configured/cached IP stops answering, so DHCP churn doesn't break it.
  * Real volume readback — after sending a key we read the monitor's actual volume
    over UPnP (RenderingControl on :9197) and return it in the HTTP reply, so the
    menu-bar app can draw an accurate Apple-style volume HUD.

The FIRST key press triggers an "Allow" dialog on the monitor — accept it once
(with the G8 remote). The token is saved to TOKEN_FILE and reused forever after.
"""

import json
import os
import re
import socket
import subprocess
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from samsungtvws import SamsungTVWS

# ---------------------------------------------------------------------------
# CONFIG  — TV_IP and KNOWN_MAC are the G8's; only change if you swap monitors.
# ---------------------------------------------------------------------------
TV_IP      = "192.168.68.69"                            # primary; pin via DHCP reservation
KNOWN_MAC  = "c8:a6:ef:42:9b:be"                        # G8 WiFi MAC — used for rediscovery
LISTEN     = ("127.0.0.1", 8765)                        # local-only; the app talks here
CONFIG_DIR = os.path.expanduser("~/.config/g8-volume")
TOKEN_FILE = os.path.join(CONFIG_DIR, "token.txt")
IP_CACHE   = os.path.join(CONFIG_DIR, "last_ip.txt")
KEEPALIVE_SECS = 25                                     # keepalive / sleep-check cadence
STALE_AFTER    = 120                                    # idle secs before we distrust the socket
# ---------------------------------------------------------------------------

os.makedirs(CONFIG_DIR, exist_ok=True)

KEYS = {"up": "KEY_VOLUP", "down": "KEY_VOLDOWN", "mute": "KEY_MUTE"}

_lock = threading.Lock()      # serialise samsungtvws access (one socket)


# ---------------------------------------------------------------------------
# IP discovery (cache -> configured TV_IP -> MAC scan), all cheap & tolerant.
# ---------------------------------------------------------------------------
def _alive(ip, timeout=1.5):
    """True if `ip` answers the Samsung device-info endpoint."""
    try:
        with urllib.request.urlopen(f"http://{ip}:8001/api/v2/", timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def _read_cache():
    try:
        with open(IP_CACHE) as f:
            return f.read().strip() or None
    except OSError:
        return None


def _write_cache(ip):
    try:
        with open(IP_CACHE, "w") as f:
            f.write(ip)
    except OSError:
        pass


def _local_subnet_prefix():
    """Return the Mac's /24 prefix, e.g. '192.168.68.' (best-effort)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    finally:
        s.close()
    return ip.rsplit(".", 1)[0] + "."


def _scan_for_mac():
    """Ping-sweep the local /24 to populate ARP, then find KNOWN_MAC's IP.

    Falls back to matching any host whose :8001 device-info names the G8.
    """
    try:
        prefix = _local_subnet_prefix()
    except Exception:
        return None

    # Populate the ARP cache with a quick concurrent ping sweep.
    def _ping(host):
        subprocess.run(["ping", "-c", "1", "-W", "1", host],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    with ThreadPoolExecutor(max_workers=64) as pool:
        pool.map(_ping, [f"{prefix}{i}" for i in range(1, 255)])

    # Look the MAC up in the ARP table.
    try:
        out = subprocess.run(["arp", "-an"], capture_output=True, text=True).stdout
    except Exception:
        out = ""
    want = KNOWN_MAC.lower()
    for line in out.splitlines():
        m = re.search(r"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-f:]+)", line, re.I)
        if not m:
            continue
        ip, mac = m.group(1), _normalise_mac(m.group(2))
        if mac == want and _alive(ip):
            return ip

    # Fallback: probe each ARP host's device-info for the G8 name/model.
    hosts = re.findall(r"\((\d+\.\d+\.\d+\.\d+)\)", out)
    for ip in hosts:
        try:
            with urllib.request.urlopen(f"http://{ip}:8001/api/v2/", timeout=1.0) as r:
                dev = json.load(r).get("device", {})
            blob = f"{dev.get('name','')} {dev.get('modelName','')}".lower()
            if "odyssey" in blob or "g8" in blob:
                return ip
        except Exception:
            continue
    return None


def _normalise_mac(mac):
    """Zero-pad each octet so '0:24:27:...' compares equal to '00:24:27:...'."""
    return ":".join(p.zfill(2) for p in mac.lower().split(":"))


def discover_tv(force=False):
    """Resolve the G8's IP, caching the winner. Order: cache, TV_IP, MAC scan."""
    if not force:
        cached = _read_cache()
        if cached and _alive(cached):
            return cached
    if _alive(TV_IP):
        _write_cache(TV_IP)
        return TV_IP
    found = _scan_for_mac()
    if found:
        _write_cache(found)
        return found
    # Nothing answered (monitor asleep?) — fall back to last known / configured.
    return _read_cache() or TV_IP


# ---------------------------------------------------------------------------
# Persistent, warm samsungtvws connection.
#
# We keep ONE warm connection so presses are instant: open eagerly, run a reader
# thread so a TV-side close flips is_alive() at once, and a keepalive thread that
# reconnects in the background. discover_tv() re-resolves the IP if a reconnect fails.
#
# The hard case is waking from a long system sleep: the reader/keepalive threads are
# suspended, the TV (and its Wi-Fi) drop the socket, and on wake the socket is
# "half-open" — is_alive() still reports True, so the first press would send into a
# dead socket and only fail after a multi-second TCP timeout. Guards for that:
#   • time-based staleness — if the connection has had no successful activity for
#     STALE_AFTER seconds (a long sleep guarantees this via wall-clock), reconnect
#     proactively BEFORE sending instead of discovering the death the slow way.
#   • sleep-gap detection — the keepalive notices the wall-clock jump and warms.
#   • /warm — the menu-bar app pings it on wake, so warming starts before you even
#     reach for the volume key; a bounded retry loop covers a still-waking monitor.
# ---------------------------------------------------------------------------
_tv_ip = discover_tv()
tv = None
_last_activity = 0.0          # wall-clock time of the last successful connect/send
_warming = threading.Event()  # set while a background warm-retry loop is running


def _new_tv(ip):
    # key_press_delay defaults to 1.5s in the library — lethal for volume; force 0.
    # timeout bounds the connect handshake so an asleep TV doesn't hang reconnects.
    return SamsungTVWS(host=ip, port=8002, token_file=TOKEN_FILE,
                       name="MacVolumeBridge", key_press_delay=0, timeout=5)


def _listen(conn):
    """Drain frames so a TV-side close is seen at once, then warm a fresh socket."""
    try:
        while conn.recv():
            pass
    except Exception:
        pass
    _warm()                       # connection died — reconnect in the background


def _connect():
    """Open a fresh warm connection (+ reader) to _tv_ip. Raises if unreachable."""
    global tv, _last_activity
    t = _new_tv(_tv_ip)
    t.open()                      # TLS + token handshake (the slow part) up front
    t.connection.settimeout(None)  # but the reader must block indefinitely, not time out
    threading.Thread(target=_listen, args=(t.connection,), daemon=True).start()
    tv = t
    _last_activity = time.time()
    return t


def force_reconnect():
    """Drop any existing socket and build a fresh one (re-discovering the IP if needed)."""
    global tv, _tv_ip
    try:
        if tv is not None:
            tv.close()
    except Exception:
        pass
    tv = None
    try:
        return _connect()
    except Exception:
        _tv_ip = discover_tv(force=True)
        return _connect()


def _is_fresh():
    """Live AND recently active — so we trust it without a slow round-trip probe."""
    return tv is not None and tv.is_alive() and (time.time() - _last_activity) < STALE_AFTER


def _ensure_connection():
    """Return a connection that's live and recently active, reconnecting otherwise."""
    return tv if _is_fresh() else force_reconnect()


def _warm():
    """Best-effort: ensure the connection is up (reader/keepalive use this)."""
    try:
        with _lock:
            _ensure_connection()
    except Exception:
        pass


def _warm_retry_loop():
    """Keep (re)establishing the connection for a while — used on wake, when the
    monitor's Wi-Fi may still be reassociating and the first attempt can fail."""
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            _warm()
            if _is_fresh():
                return
            time.sleep(2)
    finally:
        _warming.clear()


def request_warm():
    """Kick a single background warm-retry loop (no-op if one is already running)."""
    if not _warming.is_set():
        _warming.set()
        threading.Thread(target=_warm_retry_loop, daemon=True).start()


def _keepalive_loop():
    """Keep the socket warm, and force a reconnect after a system-sleep gap."""
    last = time.time()
    _warm()                                          # eager connect at startup
    while True:
        time.sleep(KEEPALIVE_SECS)
        now = time.time()
        slept = (now - last) > KEEPALIVE_SECS * 2    # wall-clock jump ⇒ we were suspended
        last = now
        request_warm() if slept else _warm()


def press(key, cmd="Click"):
    """Send one remote command over the warm socket, reconnecting if it's stale/dead.

    cmd is "Click" (one step), "Press" (start a native hold-to-ramp) or "Release".
    """
    global _last_activity
    with _lock:
        try:
            _ensure_connection().send_key(key, key_press_delay=0, cmd=cmd)
        except Exception:
            force_reconnect().send_key(key, key_press_delay=0, cmd=cmd)
        _last_activity = time.time()


# ---------------------------------------------------------------------------
# No volume readback.
#
# The keys drive the G8's volume stage, which on this setup passes audio out over
# ARC to an external (non-Samsung) soundbar via HDMI-CEC. The real level therefore
# lives in that soundbar, not the monitor — confirmed unreadable from every
# Samsung-side source (UPnP RenderingControl, the samsungtvws socket, and even the
# SmartThings cloud audioVolume all stay decoupled/pinned). So the menu-bar app
# shows a RELATIVE up/down/mute HUD driven straight from the keypress, and the
# daemon just relays keys. The only state worth reporting is the resolved IP.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Local HTTP control surface (127.0.0.1 only).
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client (or a daemon restart) closed the socket early — ignore

    def do_GET(self):
        path = self.path.strip("/").lower()

        if path == "status":
            self._json(200, {"ok": True, "tv_ip": _tv_ip})
            return

        if path == "warm":
            # The app pings this on wake / output-change so the (re)connect starts
            # before the first keypress. Returns immediately; warming runs in back.
            request_warm()
            self._json(200, {"ok": True, "tv_ip": _tv_ip})
            return

        # "up"/"down"/"mute" → a single Click; "press/up" or "release/down" →
        # start/stop a native hold-to-ramp on the monitor.
        parts = path.split("/")
        cmd, name = "Click", parts[0]
        if len(parts) == 2 and parts[0] in ("press", "release"):
            cmd, name = parts[0].capitalize(), parts[1]

        key = KEYS.get(name)
        if key is None:
            self._json(404, {"error": "unknown command"})
            return

        try:
            press(key, cmd)
        except Exception as exc:
            self.log_error("send failed: %s", exc)
            self._json(502, {"error": str(exc)})
            return

        self._json(200, {"ok": True, "tv_ip": _tv_ip})

    def log_message(self, format, *args):   # keep the console quiet
        pass


if __name__ == "__main__":
    print(f"G8 volume bridge listening on http://{LISTEN[0]}:{LISTEN[1]}  ->  {_tv_ip}",
          flush=True)
    print("First key press will pop the 'Allow' dialog on the monitor — accept it once.",
          flush=True)
    # Warm the connection now and keep it warm, so presses don't pay the handshake.
    threading.Thread(target=_keepalive_loop, daemon=True).start()
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()

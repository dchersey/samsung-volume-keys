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
DMR_PORT   = 9197                                       # UPnP MediaRenderer port
RC_CONTROL = "/upnp/control/RenderingControl1"          # RenderingControl controlURL
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
# samsungtvws connection (rebuilt on failure, re-discovering the IP).
# ---------------------------------------------------------------------------
def _build(ip):
    # key_press_delay defaults to 1.5s in the library — lethal for volume; force 0.
    return SamsungTVWS(host=ip, port=8002, token_file=TOKEN_FILE,
                       name="MacVolumeBridge", key_press_delay=0)


_tv_ip = discover_tv()
tv = _build(_tv_ip)


def press(key):
    """Send one key, rebuilding (and re-discovering) once if the socket is stale."""
    global tv, _tv_ip
    with _lock:
        try:
            tv.send_key(key, key_press_delay=0)
        except Exception:
            _tv_ip = discover_tv(force=True)
            tv = _build(_tv_ip)
            tv.send_key(key, key_press_delay=0)


# ---------------------------------------------------------------------------
# UPnP RenderingControl — read the monitor's REAL volume/mute for the HUD.
# ---------------------------------------------------------------------------
def _soap(action, body_inner, timeout=2.0):
    url = f"http://{_tv_ip}:{DMR_PORT}{RC_CONTROL}"
    envelope = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        f'<u:{action} xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">'
        f'<InstanceID>0</InstanceID>{body_inner}</u:{action}>'
        '</s:Body></s:Envelope>'
    ).encode()
    req = urllib.request.Request(url, data=envelope, headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPACTION": f'"urn:schemas-upnp-org:service:RenderingControl:1#{action}"',
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def get_volume():
    try:
        xml = _soap("GetVolume", "<Channel>Master</Channel>")
        m = re.search(r"<CurrentVolume>(\d+)</CurrentVolume>", xml)
        return int(m.group(1)) if m else None
    except Exception:
        return None


def get_mute():
    try:
        xml = _soap("GetMute", "<Channel>Master</Channel>")
        m = re.search(r"<CurrentMute>([01])</CurrentMute>", xml)
        return (m.group(1) == "1") if m else None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Volume model.
#
# This monitor's UPnP RenderingControl volume is DECOUPLED from the ARC/soundbar
# volume that KEY_VOLUP/DOWN actually drive (GetVolume stays pinned regardless),
# so we can't read the real level. Instead we track it optimistically: ±1 per
# key, toggle on mute, clamp 0-100. The clamps self-resync at the extremes (hold
# down to 0 or up to 100 and both our counter and the real volume bottom/top out
# together). Seeded once from UPnP as a rough starting guess.
# ---------------------------------------------------------------------------
_state = {"volume": None, "muted": False}


def _seed_state():
    if _state["volume"] is None:
        v = get_volume()
        _state["volume"] = v if v is not None else 50
        m = get_mute()
        _state["muted"] = bool(m) if m is not None else False


def adjust(cmd):
    _seed_state()
    if cmd == "up":
        _state["muted"] = False                       # Samsung unmutes on volume change
        _state["volume"] = min(100, _state["volume"] + 1)
    elif cmd == "down":
        _state["muted"] = False
        _state["volume"] = max(0, _state["volume"] - 1)
    elif cmd == "mute":
        _state["muted"] = not _state["muted"]


def volume_state():
    _seed_state()
    return {"volume": _state["volume"], "muted": _state["muted"], "tv_ip": _tv_ip}


# ---------------------------------------------------------------------------
# Local HTTP control surface (127.0.0.1 only).
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.strip("/").lower()

        if path == "status":
            self._json(200, {"ok": True, **volume_state()})
            return

        key = KEYS.get(path)
        if key is None:
            self._json(404, {"error": "unknown command"})
            return

        try:
            press(key)
        except Exception as exc:
            self.log_error("send failed: %s", exc)
            self._json(502, {"error": str(exc)})
            return

        # Update our optimistic level model and return it for the HUD.
        adjust(path)
        self._json(200, volume_state())

    def log_message(self, format, *args):   # keep the console quiet
        pass


if __name__ == "__main__":
    print(f"G8 volume bridge listening on http://{LISTEN[0]}:{LISTEN[1]}  ->  {_tv_ip}",
          flush=True)
    print("First key press will pop the 'Allow' dialog on the monitor — accept it once.",
          flush=True)
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()

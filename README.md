# Mac volume keys → Samsung Odyssey G8 (→ soundbar over ARC)

macOS sends raw/bitstream audio to the Odyssey G8 over HDMI/ARC, so the Mac's
keyboard volume keys can't attenuate it — the slider does nothing while the G8 is
the output. This drives the **monitor's own volume stage** instead, over the
WebSocket remote API Samsung exposes for SmartThings. It works identically whether
ARC is carrying PCM or a bitstream, with no software attenuation on the Mac.

Two pieces:

- **`G8 Volume.app`** — a tiny, code-signed SwiftUI menu-bar app (no Dock icon). It
  captures the keyboard volume/mute keys (`CGEventTap`) and reads the active output
  device (CoreAudio). **Only when the G8 is the active output** does it hijack the
  keys; otherwise it passes them straight through so native macOS volume behavior is
  fully restored. It also draws an Apple-style on-screen volume HUD showing the
  monitor's **real** level (read back over UPnP), since macOS won't draw its own once
  we swallow the key.
- **`g8_volume_bridge.py`** — an always-on local daemon (LaunchAgent) holding one
  persistent WebSocket to the G8. It converts `http://127.0.0.1:8765/up|down|mute`
  into `KEY_VOLUP` / `KEY_VOLDOWN` / `KEY_MUTE`, and after each key reads the
  monitor's actual volume/mute over UPnP and returns it for the HUD.

```
 ┌───────────────────────────────────────────────┐
 │  G8 Volume.app (signed SwiftUI, menu-bar only) │  [🔊] green = active on G8
 │  • CGEventTap on media keys (Accessibility)    │
 │  • CoreAudio: is the G8 the active output?     │
 │      yes → swallow key + ping daemon + show HUD │
 │      no  → pass event through (native keys)     │
 └───────────────┬───────────────────▲───────────┘
        HTTP GET │ /up|down|mute      │ JSON {volume,muted,tv_ip}
                 ▼ 127.0.0.1:8765     │
 ┌───────────────────────────────────────────────┐
 │  g8_volume_bridge.py (venv, LaunchAgent)       │
 │  • persistent samsungtvws WebSocket → G8 :8002 │
 │  • UPnP GetVolume/GetMute → real level (:9197) │
 │  • discover_tv(): cache → TV_IP → MAC scan     │
 └──────┬─────────────────────────────────────────┘
   wss  │ :8002 (token, self-signed TLS)
        ▼  KEY_VOLUP/DOWN/MUTE → G8 OSD volume → soundbar over ARC
```

## Install

```
./install.sh
```

This creates a Python venv (+ `samsungtvws`), loads the daemon LaunchAgent, and
builds, signs, and installs the menu-bar app. Then do the **two one-time manual
steps** macOS requires:

1. **Grant Accessibility.** System Settings → Privacy & Security → Accessibility →
   enable **G8 Volume**. The volume-key tap is inert without it. (If macOS also
   asks for **Input Monitoring**, grant that too.) The app is code-signed with a
   stable identity, so this grant persists across rebuilds.
2. **Pair with the monitor.** With the G8 as your audio output, press a volume key.
   The monitor pops an **"Allow this device?"** dialog — accept it once with the G8
   remote. The token is saved to `~/.config/g8-volume/token.txt` and reused forever.

That's it. With the G8 as output, the volume keys move the monitor (and the
soundbar over ARC) and show the level HUD. Switch to headphones or another monitor
and the keys behave normally again; the menu-bar icon dims.

## Configuration

Defaults are pinned to this machine's G8 and rarely need changing
(top of `g8_volume_bridge.py`):

- `TV_IP = "192.168.68.69"` — the G8's LAN address. It's on WiFi, so set a **DHCP
  reservation** to keep it stable. If it changes anyway, the daemon self-heals:
  `discover_tv()` ping-sweeps the subnet and finds the monitor by its WiFi MAC
  (`KNOWN_MAC`), caching the result in `~/.config/g8-volume/last_ip.txt`.
- `Audio.targetSubstring = "g8"` (in `macos/MenuBar/Sources/G8Volume/Audio.swift`)
  — the substring matched against the output-device name. "G8" matches
  "Odyssey G85SD" but not the "Odyssey G93SC" second monitor.

## Verify

```
curl -s 127.0.0.1:8765/status          # {"ok":true,"tv_ip":"192.168.68.69","volume":14,"muted":false}
curl -s 127.0.0.1:8765/up              # nudges volume up, returns the new level
curl  http://192.168.68.69:8001/api/v2/   # the G8's device info (reachability)
launchctl print gui/$(id -u)/org.hersey.g8-volume | head   # agent state
tail -f ~/Library/Logs/g8-volume.log
```

## Uninstall

```
./priv/launchd/install.sh uninstall                 # stop + remove the daemon
rm -rf "/Applications/G8 Volume.app"                # remove the app
# then remove "G8 Volume" from System Settings → Login Items, and revoke its
# Accessibility grant if you wish. State lives in ~/.config/g8-volume/.
```

## Notes

- The HTTP listener binds to `127.0.0.1` only — nothing off-box can reach it.
- `key_press_delay` is forced to `0` (the library default of 1.5s would make volume
  crawl).
- **Hold-to-ramp:** the tap steps once per key event and relies on macOS
  auto-repeating a held volume key. If a held key only steps once on your setup, add
  a `Timer`-driven repeat in `KeyTap.swift` on key-down / cancel on key-up.
- The daemon rebuilds the WebSocket automatically (and re-runs discovery) if the
  monitor drops the socket on sleep/power-cycle.

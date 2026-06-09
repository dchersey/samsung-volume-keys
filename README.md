# G8 Volume

[![CI](https://github.com/dchersey/samsung-volume-keys/actions/workflows/ci.yml/badge.svg)](https://github.com/dchersey/samsung-volume-keys/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-black.svg)

A macOS menu-bar app that makes your keyboard's **volume keys actually work** when
your Mac's sound is going out to a Samsung Odyssey G8 monitor (and whatever soundbar
hangs off it over ARC) — the one thing macOS itself flatly refuses to do.

## The problem

I run my Mac into a Samsung Odyssey G8, with a soundbar on the monitor's ARC port.
Great picture, great sound — except the **keyboard volume keys are dead**. Tap
volume-up and you get the circle-slash "nope" HUD; the menu-bar slider moves but
nothing gets louder.

The reason is subtle: macOS hands the monitor a **raw / bitstream audio signal** and
does no attenuation of its own — the actual volume lives downstream, in the
**monitor's volume stage** (which then drives the soundbar over ARC). There's
nothing on the Mac side to turn down, so the volume keys have nothing to act on.
Every "fix" that lowers the Mac's digital level either does nothing (bitstream) or
quietly degrades the audio.

The right knob to turn is the monitor's own. And it turns out Samsung exposes one:
the same **WebSocket remote API its SmartThings app uses**. So this little bridge
listens for the volume keys and drives the monitor's volume directly — full digital
scale preserved, works the same whether ARC is carrying PCM or Dolby.

## What it does

- **Makes Volume Up / Down / Mute drive the G8** (and the soundbar over ARC),
  instead of doing nothing.
- **Only when the G8 is your active output.** Switch to AirPods, headphones, or
  another display and the keys behave 100% natively again — it gets completely out
  of the way.
- **Shows an on-screen cue.** Since it has to swallow the key (so macOS doesn't draw
  its no-op HUD), it pops a small **relative** ▲ / ▼ / muted overlay, top-center,
  like the system one. (Why relative and not a 0–100 bar?
  [See below](#why-the-hud-is-relative) — the short version is that the real level
  lives in an external soundbar nothing on the network can read.)
- **Lives in the menu bar, not the Dock.** The icon goes green when the G8 is the
  active output (keys are being hijacked) and dim otherwise. The menu shows the
  output device, daemon health, mute state, and a **Launch at Login** toggle.
- **Just runs.** A tiny background daemon autostarts at login, holds one persistent
  connection to the monitor, reconnects itself if the monitor sleeps, and even
  **re-finds the monitor by its Wi-Fi MAC** if DHCP moves its IP.

## How it works

Two pieces, talking over localhost:

- A **code-signed SwiftUI menu-bar app** (`macos/MenuBar`). It taps the keyboard's
  media keys with a HID-level `CGEventTap`, checks the current output device via
  CoreAudio, and — only when that's the G8 — swallows the key and pings the daemon.
  Code-signed with a stable identity so the macOS permission grants survive rebuilds.
- A **small always-on Python daemon** (`g8_volume_bridge.py`, run as a LaunchAgent).
  It holds one persistent [`samsungtvws`](https://pypi.org/project/samsungtvws/)
  WebSocket to the monitor and turns `http://127.0.0.1:8765/up|down|mute` into
  `KEY_VOLUP` / `KEY_VOLDOWN` / `KEY_MUTE`. A daemon (rather than a script per
  keypress) keeps a single warm connection, so fast key-repeats stay smooth and
  there's no per-press handshake.

```
 ┌───────────────────────────────────────────────┐
 │  G8 Volume.app (signed SwiftUI, menu-bar only) │  [🔊] green = active on G8
 │  • HID CGEventTap on media keys                 │
 │    (Accessibility + Input Monitoring)           │
 │  • CoreAudio: is the G8 the active output?      │
 │      yes → swallow key + ping daemon + show HUD │
 │      no  → pass event through (native keys)     │
 └───────────────┬─────────────────────────────────┘
        HTTP GET │ /up|down|mute   (relative HUD shown locally)
                 ▼ 127.0.0.1:8765
 ┌───────────────────────────────────────────────┐
 │  g8_volume_bridge.py (venv, LaunchAgent)        │
 │  • persistent samsungtvws WebSocket → G8 :8002  │
 │  • discover_tv(): cache → TV_IP → MAC scan      │
 └──────┬─────────────────────────────────────────┘
   wss  │ :8002 (token, self-signed TLS)
        ▼  KEY_VOLUP/DOWN/MUTE → G8 volume stage → soundbar over ARC
```

## Install

```
git clone https://github.com/dchersey/samsung-volume-keys.git
cd samsung-volume-keys
./install.sh
```

`install.sh` creates a Python venv (+ `samsungtvws`), loads the daemon LaunchAgent,
and builds, signs, and installs the menu-bar app. It needs the Swift toolchain
(Xcode or the Command Line Tools) and Homebrew Python.

Then do the **two one-time manual steps** macOS requires — the app's menu shows a
warning button for each until it's done:

1. **Grant two permissions** in System Settings → Privacy & Security, then relaunch
   the app:
   - **Accessibility** → enable **G8 Volume** — lets the app create an
     event-altering tap (so it can suppress the key's no-op macOS HUD).
   - **Input Monitoring** → enable **G8 Volume** — lets that tap actually *receive*
     the key events. **Both are required**; with only Accessibility the tap is
     created but never sees a keypress.
2. **Pair with the monitor.** With the G8 as your audio output, press a volume key.
   The monitor pops an **"Allow this device?"** dialog — accept it once with the G8
   remote. The token is saved to `~/.config/g8-volume/token.txt` and reused forever.

That's it. With the G8 as output, the volume keys drive the monitor and show the
relative HUD; switch to anything else and they behave natively again.

## Configuration

The defaults at the top of `g8_volume_bridge.py` are pinned to one G8 and rarely
need changing:

- `TV_IP` — the monitor's LAN address. It's often on Wi-Fi, so a **DHCP
  reservation** keeps it stable. If it moves anyway, the daemon self-heals:
  `discover_tv()` ping-sweeps the subnet and finds the monitor by its Wi-Fi MAC
  (`KNOWN_MAC`), caching the result in `~/.config/g8-volume/last_ip.txt`.
- `Audio.targetSubstring` (in `macos/MenuBar/Sources/G8Volume/Audio.swift`) — the
  substring matched against the output-device name to decide "is this the G8?". The
  default `"G8"` matches `Odyssey G85SD` while excluding, say, an `Odyssey G93SC`.

## Why the HUD is relative

The keys drive the G8's volume stage, which passes audio out over ARC to an
external (often non-Samsung) soundbar via HDMI-CEC — so the *real* level lives in
that soundbar, not the monitor. That level turns out to be unreadable from every
Samsung-side source I tried: UPnP RenderingControl `GetVolume`, the `samsungtvws`
socket, and even the SmartThings cloud `audioVolume` capability all report the
monitor's idle internal volume, decoupled from the ARC output. Rather than show a
number that would be wrong, the HUD is a relative up/down/mute indicator, driven
straight from the keypress. (Volume changes are open-loop either way — the same as
pressing the buttons on a remote.)

## Verify

```
curl -s 127.0.0.1:8765/status                # {"ok":true,"tv_ip":"..."}
curl -s 127.0.0.1:8765/up                    # sends KEY_VOLUP to the monitor
curl  http://<TV_IP>:8001/api/v2/            # the G8's device info (reachability)
launchctl print gui/$(id -u)/org.hersey.g8-volume | head
tail -f ~/Library/Logs/g8-volume.log
```

## Uninstall

```
./priv/launchd/install.sh uninstall          # stop + remove the daemon
rm -rf "/Applications/G8 Volume.app"         # remove the app
# then remove "G8 Volume" from System Settings → Login Items, and revoke its
# Accessibility + Input Monitoring grants if you wish. State lives in
# ~/.config/g8-volume/.
```

## Notes

- The HTTP listener binds to `127.0.0.1` only — nothing off-box can reach it.
- `key_press_delay` is forced to `0` (the library default of 1.5s would make volume
  crawl).
- **Hold-to-ramp:** the tap steps once per key event and relies on macOS
  auto-repeating a held volume key. If a held key only steps once on your setup, add
  a `Timer`-driven repeat in `KeyTap.swift` on key-down / cancel on key-up.

## License

MIT — see [LICENSE](LICENSE).

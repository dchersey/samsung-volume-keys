# G8 Volume

[![CI](https://github.com/dchersey/samsung-volume-keys/actions/workflows/ci.yml/badge.svg)](https://github.com/dchersey/samsung-volume-keys/actions/workflows/ci.yml)
[![License: Source Available](https://img.shields.io/badge/license-Source%20Available%20(MIT%20%2B%20Commons%20Clause)-blue.svg)](LICENSE)
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
- **Hold to ramp.** Holding a volume key sends the monitor one *Press* and, on
  release, one *Release* — so the G8 runs its own native volume ramp and stops the
  instant you let go. No flooding the TV with one keypress per step (which would
  back up and keep getting louder after release).
- **Lives in the menu bar, not the Dock.** The icon goes green when the G8 is the
  active output (keys are being hijacked) and dim otherwise. The menu shows the
  output device, daemon health, mute state, and a **Launch at Login** toggle.
- **Just runs.** The app spawns the daemon at login and supervises it; the daemon
  holds one persistent connection to the monitor, reconnects itself if it sleeps,
  and **re-finds the monitor in the ARP cache** if DHCP moves its IP.

## How it works

Two pieces, talking over localhost — but **one app**: the daemon ships inside the
app bundle and the app spawns it as a **child process** (see "Why the app owns the
daemon" below).

- A **code-signed SwiftUI menu-bar app** (`macos/MenuBar`). It taps the keyboard's
  media keys with a HID-level `CGEventTap`, checks the current output device via
  CoreAudio, and — only when that's the G8 — swallows the key and pings the daemon.
  Code-signed with a stable identity so the macOS permission grants survive rebuilds.
- A **small Python daemon** (`g8_volume_bridge.py`, bundled at
  `Contents/Resources/daemon/`, run via `boot.sh` in a venv under
  `~/Library/Application Support/g8-volume/`). It holds one persistent
  [`samsungtvws`](https://pypi.org/project/samsungtvws/) WebSocket to the monitor and
  turns `http://127.0.0.1:8765/up|down|mute|press/…|release/…` into the matching
  remote keys. A persistent daemon (rather than a script per keypress) keeps one warm
  connection, so key-repeats stay smooth and there's no per-press handshake.

```
 ┌───────────────────────────────────────────────┐
 │  G8 Volume.app (signed SwiftUI, menu-bar only) │  [🔊] green = active on G8
 │  • HID CGEventTap on media keys                 │
 │    (Accessibility + Input Monitoring)           │
 │  • CoreAudio: is the G8 the active output?      │
 │      yes → swallow key + ping daemon + show HUD │
 │      no  → pass event through (native keys)     │
 │  • spawns + supervises the daemon as a child    │
 └───────────────┬─────────────────────────────────┘
        HTTP GET │ /up|down|mute|press·release   (HUD shown locally)
                 ▼ 127.0.0.1:8765   (child process → Local Network grant = the app)
 ┌───────────────────────────────────────────────┐
 │  g8_volume_bridge.py (bundled, venv)            │
 │  • persistent samsungtvws WebSocket → G8 :8002  │
 │  • discover_tv(): ARP cache (tracks DHCP)       │
 └──────┬─────────────────────────────────────────┘
   wss  │ :8002 (token, self-signed TLS)
        ▼  KEY_VOLUP/DOWN/MUTE → G8 volume stage → soundbar over ARC
```

## Why the app owns the daemon

macOS 15+ **Local Network privacy** gates LAN connections on the *responsible*
process. A standalone launchd daemon is responsible for itself — the Python binary —
so a venv rebuilt against a new interpreter (after a Homebrew Python upgrade) is a
*new binary that silently loses the grant*, and the keys quietly stop working. By
bundling the daemon and spawning it as a **child of the signed app**, its LAN access
is attributed to **G8 Volume**'s stable code signature: you grant it once and it
survives Python upgrades. (This is also why there's no LaunchAgent.)

## Install

Apple Silicon, macOS 14+, and Homebrew Python.

### Download (prebuilt, no Xcode)

Installs the **signed & notarized** app plus the background daemon:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dchersey/samsung-volume-keys/main/install.sh)"
```

### From source

Builds and signs the app locally (needs the Swift toolchain — Xcode or the Command
Line Tools):

```
git clone https://github.com/dchersey/samsung-volume-keys.git
cd samsung-volume-keys
./install.sh
```

Either way, `install.sh` sets up a Python venv (+ `samsungtvws`), installs the
menu-bar app, and loads the daemon LaunchAgent. Then do the **one-time manual
steps** macOS requires — the app's HUD/menu point you at each:

1. **Grant the app two permissions** in System Settings → Privacy & Security, then
   relaunch the app:
   - **Accessibility** → enable **G8 Volume** — lets the app create an
     event-altering tap (so it can suppress the key's no-op macOS HUD).
   - **Input Monitoring** → enable **G8 Volume** — lets that tap actually *receive*
     the key events. **Both are required**; with only Accessibility the tap is
     created but never sees a keypress.
2. **Grant Local Network access.** System Settings → Privacy & Security →
   **Local Network** → enable **G8 Volume**. macOS 15+ blocks LAN connections by
   default, so without this the daemon can't reach the monitor (the keys do nothing).
   The daemon runs as a child of the signed app, so this grant attaches to **G8
   Volume** and survives Python upgrades. If a key ever stops working, the on-screen
   HUD says exactly which toggle it needs.
3. **Pair with the monitor.** With the G8 as your audio output, press a volume key.
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
pgrep -lf g8_volume_bridge.py                # the daemon (a child of the app)
tail -f ~/Library/Logs/g8-volume.log
```

## Uninstall

```
# Quit "G8 Volume" (its menu → Quit) — that stops the daemon too — then:
rm -rf "/Applications/G8 Volume.app"                 # the app (carries the daemon)
rm -rf "$HOME/Library/Application Support/g8-volume"  # venv + token + ip cache
# Then remove "G8 Volume" from System Settings → Login Items, and revoke its
# Accessibility / Input Monitoring / Local Network grants if you wish.
```

## Notes

- The HTTP listener binds to `127.0.0.1` only — nothing off-box can reach it.
- `key_press_delay` is forced to `0` (the library default of 1.5s would make volume
  crawl).
- **Hold-to-ramp** uses the monitor's native `Press`/`Release` (one of each per
  hold), so the ramp speed and stop are the G8's own — there's an inherent ~one
  round-trip of latency, same as a single press. A watchdog releases automatically
  if a key-up is ever missed (e.g. you switch outputs mid-hold).
- **Wake / long idle.** After a long idle (especially system sleep) the monitor and
  its Wi-Fi drop the WebSocket while the daemon's reader/keepalive threads are
  suspended, leaving a "half-open" socket that looks alive but isn't — historically
  the first press then stalled for seconds while TCP timed out. The daemon now treats
  a connection with no activity for `STALE_AFTER` (120s) as suspect and reconnects
  *before* sending, detects the wall-clock jump from sleep, and exposes `/warm`; the
  menu-bar app pings `/warm` on system wake, display wake, and when the G8 becomes
  the active output, so the (re)connect starts before you reach for the keys.
- **Self-healing venv.** The app runs `boot.sh`, which rebuilds the venv if its
  Python is missing (e.g. a Homebrew `python@3.13 → 3.14` upgrade deletes the
  interpreter the venv pointed at) before launching the daemon — so a `brew upgrade`
  doesn't brick the bridge. Because the daemon is a child of the signed app, the
  Local Network grant rides on **G8 Volume**, not the rebuilt Python binary, so it
  survives the upgrade.
- **Flaky Wi-Fi / DHCP churn.** Discovery is ARP-first (instant, tracks IP changes
  with no ping sweep), reconnects are bounded, and a press that can't reach the
  monitor **fails fast with an on-screen error** instead of hanging. Pin a **DHCP
  reservation** for the monitor (and prefer a stable connection) to avoid the churn
  entirely.

## Why this license?

Samsung Volume Keys is free to use, modify, and share for any **noncommercial** purpose —
personal use, hobby projects, tinkering, learning, and contributions back are all
welcome and always will be. The one thing the license doesn't permit is **selling**
the software (or charging for hosting/support whose value comes mainly from it).

I built this to solve my own problem and I'm happy to share it freely; I just don't
want it repackaged and sold out from under the people it's meant to help. If you
have a commercial use in mind, get in touch and we can sort something out.

## License

Source-available under the **MIT License with the Commons Clause** — free to use, modify, and redistribute for any **noncommercial** purpose; you may not sell the software. See [LICENSE](LICENSE).

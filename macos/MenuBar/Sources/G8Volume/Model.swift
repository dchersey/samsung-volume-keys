import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// App state: which device is active, daemon health, and the last known level.
/// Owns the KeyTap and drives the HUD when a hijacked key fires.
@MainActor
@Observable
final class StatusModel {
  var outputName: String = "—"
  var isG8: Bool = false
  var daemonOK: Bool = false
  var accessibility: Bool = false   // lets us CREATE an active (suppressing) tap
  var inputMonitoring: Bool = false // lets the tap RECEIVE key/system events
  var launchAtLogin: Bool = false
  var tvIP: String = "—"
  // Mute is tracked locally (toggled per mute press, cleared on any volume change),
  // since the real level/mute isn't readable from the monitor. Best-effort: drifts
  // only if you also mute with the physical remote.
  var muted: Bool = false

  @ObservationIgnored private let keyTap = KeyTap()
  @ObservationIgnored private let daemon = DaemonManager()
  @ObservationIgnored private var timer: Timer?

  init() {
    requestPermissions()

    // Spawn the daemon as our child so its Local Network access is attributed to this
    // signed app (survives Python upgrades). Its first monitor connection triggers the
    // one-time "G8 Volume wants to access your local network" prompt.
    daemon.start()

    keyTap.onTrigger = { [weak self] cmd, isDown in
      self?.onKey(cmd, isDown: isDown)
    }
    keyTap.start()

    registerWakeObservers()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.daemon.stop() }   // don't orphan the daemon on quit
    }

    refresh()
    warmDaemon()   // warm the connection at launch, too
    log.notice("perms accessibility=\(self.accessibility) inputMonitoring=\(self.inputMonitoring)")
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// Prompt for BOTH grants the suppressing media-key tap needs:
  ///  • Accessibility   → permission to create an active (event-altering) tap
  ///  • Input Monitoring → permission for that tap to actually receive the events
  /// Without Input Monitoring the tap is created but no events are ever delivered.
  private func requestPermissions() {
    // String literal of kAXTrustedCheckOptionPrompt — referencing the global C
    // var trips Swift 6 concurrency checking, and this key is stable.
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if !CGPreflightListenEventAccess() {
      CGRequestListenEventAccess()   // pops the Input Monitoring prompt
    }
  }

  // Hold-to-ramp via the monitor's native Press/Release: one Press on key-down, one
  // Release on key-up. The G8 ramps itself and stops exactly on release — no per-step
  // flooding and no backlog to unwind. Auto-repeat key-downs are ignored (the TV is
  // already ramping). A watchdog, re-armed by those repeats, releases everything if a
  // key-up is ever missed (e.g. the output switched mid-hold).
  @ObservationIgnored private var heldDirs: Set<String> = []   // "up"/"down" held now
  @ObservationIgnored private var muteHeld = false
  @ObservationIgnored private var holdWatchdog: Timer?
  @ObservationIgnored private var sendChain: Task<Void, Never> = Task {}

  /// A hijacked volume key changed state (isDown: true = press, false = release).
  private func onKey(_ cmd: String, isDown: Bool) {
    if cmd == "mute" {                       // a toggle, not a hold → single Click on press
      if !isDown { muteHeld = false; return }
      if muteHeld { return }                 // ignore auto-repeat
      muteHeld = true
      muted.toggle()
      VolumeHUD.shared.show(action: "mute", muted: muted, device: outputName)
      enqueueSend("mute", primary: true)
      return
    }

    // up / down → Press on the first key-down, Release on key-up.
    if isDown {
      VolumeHUD.shared.show(action: cmd, muted: false, device: outputName)
      armWatchdog()
      if heldDirs.insert(cmd).inserted {     // first press → start the native ramp
        muted = false
        enqueueSend("press/\(cmd)", primary: true)
      }                                      // repeats: just keep the HUD + watchdog alive
    } else {
      if heldDirs.remove(cmd) != nil {
        enqueueSend("release/\(cmd)")
      }
      if heldDirs.isEmpty { holdWatchdog?.invalidate(); holdWatchdog = nil }
    }
  }

  /// Safety net for a missed key-up: genuine holds keep re-arming this via auto-repeat,
  /// so it only fires once events stop — then it releases whatever is still held.
  private func armWatchdog() {
    holdWatchdog?.invalidate()
    holdWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.releaseAllHeld() }
    }
  }

  private func releaseAllHeld() {
    for dir in heldDirs { enqueueSend("release/\(dir)") }
    heldDirs.removeAll()
    holdWatchdog?.invalidate()
    holdWatchdog = nil
  }

  /// Serialize sends so a Press always reaches the daemon before its Release. For a
  /// `primary` action (the initial press / mute), surface an actionable HUD error if
  /// it couldn't land — so a flap or a missing Local Network grant doesn't look like
  /// nothing happened.
  private func enqueueSend(_ path: String, primary: Bool = false) {
    let prev = sendChain
    let dev = outputName
    sendChain = Task { @MainActor in
      _ = await prev.value
      let reply = await Bridge.send(path)
      if reply?.ok == true {
        daemonOK = true
        if let ip = reply?.tv_ip { tvIP = ip }
      } else if primary {
        daemonOK = (reply != nil)                       // up (502) vs daemon down (nil)
        let hint = reply?.hint ?? (reply == nil ? "daemon" : "unreachable")
        VolumeHUD.shared.showError(hint: hint, device: dev)
      }
    }
  }

  /// Ask the daemon to (re)establish its monitor connection now, so the first
  /// keypress after an idle period / sleep doesn't pay a cold reconnect.
  func warmDaemon() {
    Task { await Bridge.warm() }
  }

  /// Warm proactively when the Mac (or its display) wakes — that's when the daemon's
  /// socket is half-open and a first press would otherwise stall for seconds.
  private func registerWakeObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.warmDaemon() }
      }
    }
  }

  /// Restart the daemon child (menu action).
  func restartDaemon() {
    daemon.restart()
  }

  /// Toggle launch-at-login from the menu checkbox.
  func setLaunchAtLogin(_ on: Bool) {
    LoginItem.setEnabled(on)
    launchAtLogin = LoginItem.isEnabled
  }

  /// Refresh output-device state and poll the daemon's health/level.
  func refresh() {
    let wasG8 = isG8
    outputName = Audio.defaultOutputDeviceName() ?? "—"
    isG8 = Audio.defaultOutputIsG8()
    if isG8 && !wasG8 { warmDaemon() }   // just became the active output → warm ahead of use

    // The tap can only be created once Accessibility is granted; retry until it
    // takes, so granting the permission "just works" without an app relaunch.
    accessibility = AXIsProcessTrusted()
    inputMonitoring = CGPreflightListenEventAccess()
    launchAtLogin = LoginItem.isEnabled
    if accessibility { keyTap.start() }

    Task { @MainActor in
      if let s = await Bridge.status() {
        daemonOK = s.ok ?? true
        if let ip = s.tv_ip { tvIP = ip }
      } else {
        daemonOK = false
      }
    }
  }
}

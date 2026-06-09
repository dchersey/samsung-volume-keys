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
  @ObservationIgnored private var timer: Timer?

  init() {
    requestPermissions()

    keyTap.onTrigger = { [weak self] cmd in
      self?.handleKey(cmd)
    }
    keyTap.start()

    refresh()
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

  /// A hijacked volume key fired. Update local mute state, show the HUD instantly
  /// (no daemon round-trip needed for a relative cue), then relay the key.
  private func handleKey(_ cmd: String) {
    switch cmd {
    case "up", "down": muted = false   // Samsung unmutes on any volume change
    case "mute": muted.toggle()
    default: break
    }
    VolumeHUD.shared.show(action: cmd, muted: muted, device: outputName)
    Task { @MainActor in
      if let reply = await Bridge.send(cmd) {
        daemonOK = true
        if let ip = reply.tv_ip { tvIP = ip }
      }
    }
  }

  /// Toggle launch-at-login from the menu checkbox.
  func setLaunchAtLogin(_ on: Bool) {
    LoginItem.setEnabled(on)
    launchAtLogin = LoginItem.isEnabled
  }

  /// Refresh output-device state and poll the daemon's health/level.
  func refresh() {
    outputName = Audio.defaultOutputDeviceName() ?? "—"
    isG8 = Audio.defaultOutputIsG8()

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

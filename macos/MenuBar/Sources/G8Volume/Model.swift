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
  var tvIP: String = "—"
  var volume: Int = 0
  var muted: Bool = false

  @ObservationIgnored private let keyTap = KeyTap()
  @ObservationIgnored private var timer: Timer?

  init() {
    requestPermissions()

    keyTap.onTrigger = { [weak self] cmd in
      self?.handleKey(cmd)
    }
    keyTap.start()

    LoginItem.register()

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

  /// A hijacked volume key fired: tell the daemon, then reflect the real level.
  private func handleKey(_ cmd: String) {
    let name = outputName
    Task { @MainActor in
      if let reply = await Bridge.send(cmd) {
        daemonOK = true
        if let v = reply.volume { volume = v }
        if let m = reply.muted { muted = m }
        if let ip = reply.tv_ip { tvIP = ip }
      }
      VolumeHUD.shared.show(volume: volume, muted: muted, device: name)
    }
  }

  /// Refresh output-device state and poll the daemon's health/level.
  func refresh() {
    outputName = Audio.defaultOutputDeviceName() ?? "—"
    isG8 = Audio.defaultOutputIsG8()

    // The tap can only be created once Accessibility is granted; retry until it
    // takes, so granting the permission "just works" without an app relaunch.
    accessibility = AXIsProcessTrusted()
    inputMonitoring = CGPreflightListenEventAccess()
    if accessibility { keyTap.start() }

    Task { @MainActor in
      if let s = await Bridge.status() {
        daemonOK = s.ok ?? true
        if let v = s.volume { volume = v }
        if let m = s.muted { muted = m }
        if let ip = s.tv_ip { tvIP = ip }
      } else {
        daemonOK = false
      }
    }
  }
}

import AppKit
import Foundation

/// Spawns and supervises the Python daemon as a CHILD of this signed app.
///
/// Why a child instead of a LaunchAgent: macOS 15+ Local Network privacy attributes
/// a connection to the *responsible* process. A launchd daemon is responsible for
/// itself (the Python binary), so a venv rebuilt against a new interpreter loses the
/// grant. As our child, the daemon's LAN access is attributed to this app's stable
/// code signature — grant "G8 Volume" once and it survives Python upgrades.
@MainActor
final class DaemonManager {
  /// Writable home for the daemon's state (venv, token, ip cache) — mirrors boot.sh.
  static let home = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("g8-volume", isDirectory: true)

  private var process: Process?
  private var stopping = false
  private var restartWork: DispatchWorkItem?

  /// The bundled daemon launcher (Contents/Resources/daemon/boot.sh).
  private var bootScript: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("daemon/boot.sh")
  }

  func start() {
    stopping = false
    spawn()
  }

  func restart() {
    restartWork?.cancel()
    detachAndTerminate()
    spawn()
  }

  /// Stop the daemon (called on app quit) so it isn't orphaned.
  func stop() {
    stopping = true
    restartWork?.cancel()
    detachAndTerminate()
  }

  private func detachAndTerminate() {
    if let p = process {
      p.terminationHandler = nil
      p.terminate()
    }
    process = nil
  }

  private func spawn() {
    guard !stopping else { return }
    guard let boot = bootScript, FileManager.default.fileExists(atPath: boot.path) else {
      NSLog("G8Volume: bundled daemon boot.sh not found")
      return
    }
    killOrphans()   // clear any daemon left over from a prior crash so :8765 is free

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [boot.path]
    p.terminationHandler = { [weak self] _ in
      Task { @MainActor in self?.onExit() }
    }
    do {
      try p.run()
      process = p
    } catch {
      NSLog("G8Volume: failed to spawn daemon: \(error.localizedDescription)")
      scheduleRestart()
    }
  }

  private func onExit() {
    process = nil
    if !stopping { scheduleRestart() }   // keep it alive across crashes
  }

  private func scheduleRestart() {
    guard !stopping else { return }
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor in self?.spawn() }
    }
    restartWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
  }

  private func killOrphans() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-f", "g8_volume_bridge.py"]
    try? p.run()
    p.waitUntilExit()
  }
}

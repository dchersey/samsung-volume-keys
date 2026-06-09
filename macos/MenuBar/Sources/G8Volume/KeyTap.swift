import AppKit
import CoreGraphics
import os

let log = Logger(subsystem: "org.hersey.g8volume", category: "tap")

// Hardware media-key codes as they appear in NSSystemDefined events.
private let NX_KEYTYPE_SOUND_UP = 0
private let NX_KEYTYPE_SOUND_DOWN = 1
private let NX_KEYTYPE_MUTE = 7

/// Intercepts the keyboard volume/mute keys with a CGEventTap. When the G8 is the
/// active output it swallows the key (so macOS draws no no-op HUD) and reports the
/// command; otherwise it passes the event straight through so the native macOS
/// volume behavior is fully restored.
///
/// Requires Accessibility (the tap is inert without it). The tap's run-loop source
/// is installed on the main run loop, so the callback fires on the main thread —
/// which is why the C trampoline can use `MainActor.assumeIsolated`.
@MainActor
final class KeyTap {
  /// Called when the G8 is the active output and a volume key went down.
  var onTrigger: ((String) -> Void)?

  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  func start() {
    guard tap == nil else { return }
    // System-defined events (media keys) have CGEventType raw value 14.
    let mask = CGEventMask(1 << 14)
    let refcon = Unmanaged.passUnretained(self).toOpaque()

    // HID-level tap: media keys are delivered (and suppressible) here, before the
    // system acts on them. The session-level tap does not receive them on recent macOS.
    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: keyTapCallback,
        userInfo: refcon)
    else {
      log.error("CGEvent.tapCreate FAILED — Accessibility not granted to this build?")
      return
    }

    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    self.runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log.notice("event tap ACTIVE")
  }

  func reEnable() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
  }

  func fire(_ cmd: String) { onTrigger?(cmd) }
}

/// Maps a media-key code to a daemon command, or nil if we don't handle it.
private func command(for keyCode: Int) -> String? {
  switch keyCode {
  case NX_KEYTYPE_SOUND_UP: return "up"
  case NX_KEYTYPE_SOUND_DOWN: return "down"
  case NX_KEYTYPE_MUTE: return "mute"
  default: return nil
  }
}

/// C callback for the tap. Decodes the event here (nonisolated, on the main
/// thread) and only hops to the main actor with the resulting command string —
/// CGEvent isn't Sendable, so it must not cross the actor boundary.
private func keyTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  let passthrough = Unmanaged.passUnretained(event)
  guard let refcon else { return passthrough }
  let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()

  // The system disables the tap if a callback is too slow or on user input; re-arm.
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    MainActor.assumeIsolated { me.reEnable() }
    return passthrough
  }

  guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
    ns.subtype.rawValue == 8
  else { return passthrough }

  let data1 = ns.data1
  let keyCode = (data1 & 0xFFFF_0000) >> 16
  let keyState = (data1 & 0x0000_FF00) >> 8
  let isDown = keyState == 0x0A

  guard let cmd = command(for: keyCode) else { return passthrough }  // not our key
  let onG8 = Audio.defaultOutputIsG8()
  log.notice("media key=\(keyCode) down=\(isDown) onG8=\(onG8) -> \(onG8 ? "HIJACK" : "passthrough")")
  guard isDown else { return nil }                                    // swallow our key-up
  guard onG8 else { return passthrough }                             // not on G8 → native

  MainActor.assumeIsolated { me.fire(cmd) }
  return nil  // swallow — we handled it
}

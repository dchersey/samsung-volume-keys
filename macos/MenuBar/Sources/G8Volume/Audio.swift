import CoreAudio
import Foundation

/// Reads the macOS default audio output device name via CoreAudio so we can tell
/// whether the G8 is the active output. (Same approach as the noise-defense
/// project's AncController.defaultOutputDeviceName.)
enum Audio {
  /// Substring (case-insensitive) that identifies the G8 in the output-device
  /// name. "G8" matches "Odyssey G85SD" but not the "Odyssey G93SC" second
  /// monitor — verified against this machine's devices.
  static let targetSubstring = "g8"

  static func defaultOutputDeviceName() -> String? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)

    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0
    else { return nil }

    var name = "" as CFString
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var nameAddr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)

    let status = withUnsafeMutablePointer(to: &name) {
      AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, $0)
    }
    return status == noErr ? (name as String) : nil
  }

  /// True when the current default output is the G8 (so we should hijack the keys).
  static func defaultOutputIsG8() -> Bool {
    guard let name = defaultOutputDeviceName() else { return false }
    return name.range(of: targetSubstring, options: .caseInsensitive) != nil
  }
}

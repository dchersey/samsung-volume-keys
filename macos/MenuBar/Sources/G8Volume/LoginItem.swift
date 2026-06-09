import AppKit
import ServiceManagement

/// Launch-at-login via the modern SMAppService API, toggled from the menu.
enum LoginItem {
  /// Whether the app is currently registered to launch at login.
  static var isEnabled: Bool {
    guard #available(macOS 13, *) else { return false }
    return SMAppService.mainApp.status == .enabled
  }

  /// Enable or disable launch-at-login (idempotent, best-effort).
  static func setEnabled(_ enabled: Bool) {
    guard #available(macOS 13, *) else { return }
    let service = SMAppService.mainApp
    do {
      if enabled {
        if service.status != .enabled { try service.register() }
      } else {
        if service.status == .enabled { try service.unregister() }
      }
    } catch {
      NSLog("G8Volume: login-item toggle failed: \(error.localizedDescription)")
    }
    // If macOS needs the user to approve it in Login Items, take them there.
    if enabled, service.status == .requiresApproval {
      SMAppService.openSystemSettingsLoginItems()
    }
  }
}

import Foundation
import ServiceManagement

/// Registers the app to launch at login via the modern SMAppService API, so the
/// menu-bar bridge comes back after a reboot. Best-effort and idempotent.
enum LoginItem {
  static func register() {
    guard #available(macOS 13, *) else { return }
    let service = SMAppService.mainApp
    do {
      if service.status != .enabled {
        try service.register()
      }
    } catch {
      NSLog("G8Volume: login-item registration failed: \(error.localizedDescription)")
    }
  }
}

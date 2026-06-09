import AppKit
import SwiftUI

@main
struct G8VolumeApp: App {
  @State private var model = StatusModel()

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      Image(nsImage: icon(active: model.isG8))
    }
    .menuBarExtraStyle(.window)
  }

  /// Green, non-template glyph when the G8 is the active output (we're hijacking);
  /// a normal template glyph (adapts to the menu bar) when idle.
  private func icon(active: Bool) -> NSImage {
    let name = active ? "speaker.wave.2.fill" : "speaker.wave.2"
    let base = NSImage(systemSymbolName: name, accessibilityDescription: "G8 Volume")
      ?? NSImage()
    guard active else {
      base.isTemplate = true
      return base
    }
    let green = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1)
    let config = NSImage.SymbolConfiguration(paletteColors: [green])
    let img = base.withSymbolConfiguration(config) ?? base
    img.isTemplate = false
    return img
  }
}

/// The dropdown shown when the menu-bar icon is clicked (.window style).
private struct MenuView: View {
  @State var model: StatusModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Circle()
          .fill(model.isG8 ? .green : .secondary)
          .frame(width: 8, height: 8)
        Text(model.isG8 ? "G8 Volume Bridge: active" : "G8 Volume Bridge: idle")
          .font(.system(size: 13, weight: .semibold))
      }

      Group {
        Text("Output: \(model.outputName)")
        Text("Daemon: \(model.daemonOK ? "ok" : "down") (tv \(model.tvIP))")
        Text("Volume: \(model.muted ? "muted" : "\(model.volume)")")
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)

      if !model.accessibility {
        permissionButton(
          "⚠︎ Grant Accessibility to enable the keys",
          pane: "Privacy_Accessibility")
      }
      if !model.inputMonitoring {
        permissionButton(
          "⚠︎ Grant Input Monitoring (then relaunch)",
          pane: "Privacy_ListenEvent")
      }

      Divider()

      Button("Restart daemon") { Bridge.restartDaemon() }
        .buttonStyle(.plain)
      Button("Quit") { NSApp.terminate(nil) }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
    }
    .padding(12)
    .frame(width: 240, alignment: .leading)
  }

  /// A warning row that opens the relevant Privacy & Security settings pane.
  private func permissionButton(_ title: String, pane: String) -> some View {
    Button {
      if let url = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
      }
    } label: {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.plain)
  }
}

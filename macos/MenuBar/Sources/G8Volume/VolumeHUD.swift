import AppKit
import SwiftUI

/// State backing the floating HUD view.
@MainActor
final class HUDState: ObservableObject {
  @Published var volume: Int = 0
  @Published var muted: Bool = false
  @Published var device: String = ""
}

/// Apple-style volume overlay. Because we swallow the media key, macOS draws no
/// HUD of its own — this is our stand-in, showing the monitor's REAL level (read
/// back from the daemon over UPnP) on a borderless, non-activating floating panel.
@MainActor
final class VolumeHUD {
  static let shared = VolumeHUD()

  private let state = HUDState()
  private var panel: NSPanel?
  private var hideTimer: Timer?

  private func makePanel() -> NSPanel {
    let size = NSSize(width: 260, height: 92)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false

    let host = NSHostingView(rootView: HUDView(state: state))
    host.frame = NSRect(origin: .zero, size: size)
    panel.contentView = host
    return panel
  }

  /// Show (or refresh) the HUD with the given level, resetting the fade timer.
  func show(volume: Int?, muted: Bool?, device: String) {
    state.volume = max(0, min(100, volume ?? state.volume))
    state.muted = muted ?? false
    state.device = device

    let panel = self.panel ?? makePanel()
    self.panel = panel
    reposition(panel)

    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.fadeOut() }
    }
  }

  private func fadeOut() {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.35
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak panel] in
      Task { @MainActor in panel?.orderOut(nil) }
    })
  }

  /// Top-center, just under the menu bar — matching the modern macOS HUD position.
  private func reposition(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let vf = screen.visibleFrame
    let w = panel.frame.width
    let h = panel.frame.height
    let x = vf.midX - w / 2
    let y = vf.maxY - h - 12
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

/// The HUD's contents: device name, speaker glyph, and a rounded level bar.
private struct HUDView: View {
  @ObservedObject var state: HUDState

  private var symbol: String {
    if state.muted { return "speaker.slash.fill" }
    switch state.volume {
    case 0: return "speaker.fill"
    case 1..<34: return "speaker.wave.1.fill"
    case 34..<67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      Text(state.device.isEmpty ? "Output" : state.device)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 18))
          .frame(width: 24)
          .foregroundStyle(.primary)

        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(.secondary.opacity(0.25))
            Capsule()
              .fill(state.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
              .frame(width: geo.size.width * CGFloat(state.muted ? 0 : state.volume) / 100)
          }
        }
        .frame(height: 6)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .tint(.green)
  }
}

import AppKit
import SwiftUI

/// State backing the floating HUD view.
@MainActor
final class HUDState: ObservableObject {
  @Published var action: String = "up"   // "up" | "down" | "mute"
  @Published var muted: Bool = false
  @Published var device: String = ""
}

/// On-screen volume feedback. Because we swallow the media key, macOS draws no HUD
/// of its own — this is our stand-in. The real (ARC/external-soundbar) level isn't
/// readable from any Samsung-side API, so this is a RELATIVE indicator: an up/down
/// chevron per press, or a muted/sound-on state, on a borderless floating panel.
@MainActor
final class VolumeHUD {
  static let shared = VolumeHUD()

  private let state = HUDState()
  private var panel: NSPanel?
  private var hideTimer: Timer?

  private func makePanel() -> NSPanel {
    let size = NSSize(width: 240, height: 96)
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

  /// Show (or refresh) the HUD for a keypress, resetting the fade timer.
  func show(action: String, muted: Bool, device: String) {
    state.action = action
    state.muted = muted
    state.device = device

    let panel = self.panel ?? makePanel()
    self.panel = panel
    reposition(panel)

    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
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
    let x = vf.midX - panel.frame.width / 2
    let y = vf.maxY - panel.frame.height - 12
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

/// The HUD's contents: device name, speaker glyph, and a relative up/down/mute cue.
private struct HUDView: View {
  @ObservedObject var state: HUDState

  private var speakerSymbol: String {
    state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
  }

  var body: some View {
    VStack(spacing: 12) {
      Text(state.device.isEmpty ? "Output" : state.device)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      HStack(spacing: 16) {
        Image(systemName: speakerSymbol)
          .font(.system(size: 26))
          .foregroundStyle(state.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
          .frame(width: 34)

        cue
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
    )
  }

  /// Up/down show a green chevron; mute shows the resulting muted/sound-on state.
  @ViewBuilder private var cue: some View {
    switch state.action {
    case "up":
      Image(systemName: "chevron.up")
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.green)
    case "down":
      Image(systemName: "chevron.down")
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.green)
    default:  // mute
      Text(state.muted ? "Muted" : "Sound on")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.secondary)
    }
  }
}

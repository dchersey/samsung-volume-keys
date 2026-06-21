import AppKit
import SwiftUI

/// State backing the floating HUD view.
@MainActor
final class HUDState: ObservableObject {
  @Published var action: String = "up"   // "up" | "down" | "mute"
  @Published var muted: Bool = false
  @Published var device: String = ""
  @Published var errorTitle: String = ""    // non-empty → show the error layout instead
  @Published var errorDetail: String = ""
}

/// On-screen volume feedback. Because we swallow the media key, macOS draws no HUD
/// of its own — this is our stand-in: a RELATIVE up/down/mute indicator, or, when a
/// keypress can't reach the monitor, an actionable error (e.g. "allow Local Network").
@MainActor
final class VolumeHUD {
  static let shared = VolumeHUD()

  private let state = HUDState()
  private var panel: NSPanel?
  private var hideTimer: Timer?

  private func makePanel() -> NSPanel {
    let size = NSSize(width: 300, height: 104)
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
    state.errorTitle = ""
    state.errorDetail = ""
    state.action = action
    state.muted = muted
    state.device = device
    present(duration: 1.1)
  }

  /// Show an actionable error when a keypress couldn't reach the monitor.
  func showError(hint: String, device: String) {
    state.device = device
    switch hint {
    case "local_network":
      state.errorTitle = "Allow “Python” local network access"
      state.errorDetail = "Settings ▸ Privacy & Security ▸ Local Network"
    case "daemon":
      state.errorTitle = "Volume bridge isn’t running"
      state.errorDetail = "Open “G8 Volume”, or Restart daemon"
    default:  // "unreachable" / "offline"
      state.errorTitle = "Can’t reach the monitor"
      state.errorDetail = "Check the G8’s network / power"
    }
    present(duration: 3.0)   // linger — it's something to act on
  }

  private func present(duration: TimeInterval) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    reposition(panel)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideTimer?.invalidate()
    hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
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

/// The HUD's contents: a relative up/down/mute cue, or an actionable error.
private struct HUDView: View {
  @ObservedObject var state: HUDState

  var body: some View {
    Group {
      if state.errorTitle.isEmpty {
        cueContent
      } else {
        errorContent
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

  private var speakerSymbol: String {
    state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
  }

  private var cueContent: some View {
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

  private var errorContent: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 24))
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 3) {
        Text(state.errorTitle)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
        if !state.errorDetail.isEmpty {
          Text(state.errorDetail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
  }
}

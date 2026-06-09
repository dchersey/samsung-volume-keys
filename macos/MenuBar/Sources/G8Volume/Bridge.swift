import Foundation

/// What the daemon reports back: the monitor's real volume/mute + resolved IP.
struct BridgeReply: Decodable {
  var ok: Bool?
  var volume: Int?
  var muted: Bool?
  var tv_ip: String?
}

/// Talks to the local Python daemon (g8_volume_bridge.py) on 127.0.0.1:8765.
enum Bridge {
  static let base = "http://127.0.0.1:8765"
  static let label = "org.hersey.g8-volume"

  /// Fire a volume command and decode the monitor's resulting state.
  /// One of "up", "down", "mute".
  @discardableResult
  static func send(_ cmd: String) async -> BridgeReply? {
    await get(cmd)
  }

  /// Poll the daemon's health + current volume without changing anything.
  static func status() async -> BridgeReply? {
    await get("status")
  }

  private static func get(_ path: String) async -> BridgeReply? {
    guard let url = URL(string: "\(base)/\(path)") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 3
    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
      else { return nil }
      return try? JSONDecoder().decode(BridgeReply.self, from: data)
    } catch {
      return nil
    }
  }

  /// Bounce the daemon LaunchAgent (menu action) via launchctl kickstart -k.
  static func restartDaemon() {
    let uid = getuid()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", "gui/\(uid)/\(label)"]
    try? p.run()
  }
}

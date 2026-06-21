import Foundation

/// What the daemon reports back: health + the resolved monitor IP, and — when a
/// send fails — a hint for why (so the HUD can say "allow Local Network", etc.).
struct BridgeReply: Decodable {
  var ok: Bool?
  var tv_ip: String?
  var error: String?
  var hint: String?
}

/// Talks to the local Python daemon (g8_volume_bridge.py) on 127.0.0.1:8765.
enum Bridge {
  static let base = "http://127.0.0.1:8765"

  /// Fire a volume command and decode the monitor's resulting state.
  /// One of "up", "down", "mute".
  @discardableResult
  static func send(_ cmd: String) async -> BridgeReply? {
    await get(cmd)
  }

  /// Poll the daemon's health without changing anything.
  static func status() async -> BridgeReply? {
    await get("status")
  }

  /// Ask the daemon to (re)establish its monitor connection now — fired on system
  /// wake / output-change so the first keypress doesn't pay a cold reconnect.
  static func warm() async {
    _ = await get("warm")
  }

  /// Returns nil only when the daemon itself is unreachable (not even localhost).
  /// Otherwise returns the decoded reply with `ok` set from the HTTP status, so a
  /// 502 (monitor send failed) still carries its `hint`.
  private static func get(_ path: String) async -> BridgeReply? {
    guard let url = URL(string: "\(base)/\(path)") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 8   // a failed press includes the daemon's bounded reconnect + probe
    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      var reply = (try? JSONDecoder().decode(BridgeReply.self, from: data)) ?? BridgeReply()
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      reply.ok = (200..<300).contains(code)
      return reply
    } catch {
      return nil
    }
  }
}

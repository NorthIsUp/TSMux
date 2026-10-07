import Foundation

/// A shell the user can open: a Tailscale SSH machine, reached through its
/// own tailnet, logged into as the user's tailnet identity maps to.
public struct ShellTarget: Sendable, Hashable {
  public var device: String  // MagicDNS name
  public var host: String  // what to dial: a Tailscale IP or the name
  public var socksAddr: String
  public var hostKeys: [String]
  public var tailnet: String
  public var user: String

  public init(
    device: String, host: String, socksAddr: String, hostKeys: [String], tailnet: String,
    user: String
  ) {
    self.device = device
    self.host = host
    self.socksAddr = socksAddr
    self.hostKeys = hostKeys
    self.tailnet = tailnet
    self.user = user
  }

  var request: SSHRequest {
    SSHRequest(socksAddr: socksAddr, host: host, user: user, hostKeys: hostKeys)
  }
}

/// Which machines get a Shell action. A client can't see the tailnet's SSH
/// rules — the server applies them when you connect — so it offers every
/// online Tailscale SSH machine and remembers, for a day, the ones that said no.
public enum SSHAccess {
  static let denialLifetime: TimeInterval = 24 * 3600
  private static let key = "sshDenied"

  /// The local user Tailscale SSH rules usually map a login to
  /// (`localpart:*@domain`): `adam@askclara.com` → `adam`.
  public static func user(login: String?) -> String? {
    guard let local = login?.prefix(while: { $0 != "@" }), !local.isEmpty else { return nil }
    return String(local)
  }

  public static func target(
    device: String, ips: [String]?, online: Bool, hostKeys: [String]?, tailnet: String,
    login: String?, socksAddr: String?, defaults: UserDefaults = .standard, now: Date = .now
  ) -> ShellTarget? {
    guard online, let hostKeys, !hostKeys.isEmpty, let socksAddr, let user = user(login: login)
    else { return nil }
    guard !isDenied(tailnet: tailnet, device: device, user: user, defaults: defaults, now: now)
    else { return nil }
    return ShellTarget(
      device: device, host: ips?.first ?? device, socksAddr: socksAddr, hostKeys: hostKeys,
      tailnet: tailnet, user: user)
  }

  static func markDenied(
    _ t: ShellTarget, defaults: UserDefaults = .standard, now: Date = .now
  ) {
    var d = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    d[id(t.tailnet, t.device, t.user)] = now.timeIntervalSince1970
    defaults.set(d, forKey: key)
  }

  static func isDenied(
    tailnet: String, device: String, user: String, defaults: UserDefaults, now: Date
  ) -> Bool {
    let d = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    guard let at = d[id(tailnet, device, user)] else { return false }
    return now.timeIntervalSince1970 - at < denialLifetime
  }

  private static func id(_ tailnet: String, _ device: String, _ user: String) -> String {
    "\(tailnet)/\(device)/\(user)"
  }
}

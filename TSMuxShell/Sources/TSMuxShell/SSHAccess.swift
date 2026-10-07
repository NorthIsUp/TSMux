import Foundation

/// A shell the user can open: a Tailscale SSH machine, reached through its
/// own tailnet, logged into as the user's tailnet identity maps to.
public struct ShellTarget: Sendable, Hashable {
  public var device: String  // MagicDNS name
  public var host: String  // what to dial: a Tailscale IP or the name
  public var socksAddr: String
  public var hostKeys: [String]
  public var tailnet: String
  /// Accounts to try, best guess first: the one that worked last time, the
  /// login's local part, then root.
  public var users: [String]

  public init(
    device: String, host: String, socksAddr: String, hostKeys: [String], tailnet: String,
    users: [String]
  ) {
    self.device = device
    self.host = host
    self.socksAddr = socksAddr
    self.hostKeys = hostKeys
    self.tailnet = tailnet
    self.users = users
  }

  /// The account the shell will most likely open as.
  public var user: String { users.first ?? "" }

  var request: SSHRequest {
    SSHRequest(
      socksAddr: socksAddr, host: host, user: user, users: Array(users.dropFirst()),
      hostKeys: hostKeys)
  }
}

/// Which machines get a Shell action, and as whom. A client can't see the
/// tailnet's SSH rules or a machine's accounts — the server checks both when
/// you connect — so it offers every online Tailscale SSH machine, tries the
/// likely accounts in turn, remembers the one that worked, and hides for a day
/// a machine that let none in.
public enum SSHAccess {
  static let denialLifetime: TimeInterval = 24 * 3600
  private static let key = "sshDenied"
  private static let usersKey = "sshUsers"

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
    guard online, let hostKeys, !hostKeys.isEmpty, let socksAddr, let local = user(login: login)
    else { return nil }
    guard !isDenied(tailnet: tailnet, device: device, defaults: defaults, now: now)
    else { return nil }
    var users = [String]()
    for u in [worked(tailnet: tailnet, device: device, defaults: defaults), local, "root"] {
      if let u, !users.contains(u) { users.append(u) }
    }
    return ShellTarget(
      device: device, host: ips?.first ?? device, socksAddr: socksAddr, hostKeys: hostKeys,
      tailnet: tailnet, users: users)
  }

  /// Remembers who the machine let in, so the next shell tries them first.
  static func rememberUser(
    _ user: String, for t: ShellTarget, defaults: UserDefaults = .standard
  ) {
    var d = defaults.dictionary(forKey: usersKey) as? [String: String] ?? [:]
    d[id(t.tailnet, t.device)] = user
    defaults.set(d, forKey: usersKey)
  }

  private static func worked(tailnet: String, device: String, defaults: UserDefaults) -> String? {
    (defaults.dictionary(forKey: usersKey) as? [String: String])?[id(tailnet, device)]
  }

  static func markDenied(
    _ t: ShellTarget, defaults: UserDefaults = .standard, now: Date = .now
  ) {
    var d = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    d[id(t.tailnet, t.device)] = now.timeIntervalSince1970
    defaults.set(d, forKey: key)
  }

  static func isDenied(
    tailnet: String, device: String, defaults: UserDefaults, now: Date
  ) -> Bool {
    let d = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    guard let at = d[id(tailnet, device)] else { return false }
    return now.timeIntervalSince1970 - at < denialLifetime
  }

  private static func id(_ tailnet: String, _ device: String) -> String {
    "\(tailnet)/\(device)"
  }
}

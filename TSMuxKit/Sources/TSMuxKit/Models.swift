import Foundation

// The daemon's JSON wire model, shared by the macOS and iOS apps.

public struct ExitNodeOption: Decodable, Sendable, Identifiable, Hashable {
  public let id: String
  public let name: String
  public let hostname: String
  public let online: Bool
  public let current: Bool
}

/// One peer in a tailnet. `owner` is empty for tagged nodes — those group
/// under their tag instead, the way the admin console presents them.
public struct Device: Decodable, Sendable, Identifiable, Hashable {
  public let name: String
  public let hostname: String
  public let ips: [String]?
  public let os: String?
  public let owner: String?
  public let tags: [String]?
  public let online: Bool
  public let exitNode: Bool?
  /// Host keys the device's Tailscale SSH server advertises; an SSH client
  /// pins these rather than asking the user to trust a fingerprint.
  public let sshHostKeys: [String]?

  public var id: String { name }

  enum CodingKeys: String, CodingKey {
    case name, hostname, ips, os, owner, tags, online
    case exitNode = "exit_node"
    case sshHostKeys = "ssh_host_keys"
  }

  /// What a plain click copies: something you can paste into a browser.
  public var url: String { "https://\(name)" }
  public var primaryIP: String? { ips?.first }
  /// The short name, which is what you type at a shell.
  public var shortName: String {
    hostname.isEmpty ? String(name.split(separator: ".").first ?? "") : hostname
  }

  /// Group heading this device belongs under.
  public var group: String {
    if let t = tags?.first, !t.isEmpty { return t }
    if let o = owner, !o.isEmpty { return o }
    return "Other"
  }
}

public struct ProfilePrefs: Decodable, Sendable, Hashable {
  /// This tailnet's own on/off state, independent of the others.
  public var connected: Bool
  public var acceptRoutes: Bool
  public var acceptDNS: Bool
  public var shieldsUp: Bool
  public var exitNode: String
  public var exitNodeAllowLAN: Bool

  enum CodingKeys: String, CodingKey {
    case connected
    case acceptRoutes = "accept_routes"
    case acceptDNS = "accept_dns"
    case shieldsUp = "shields_up"
    case exitNode = "exit_node"
    case exitNodeAllowLAN = "exit_node_allow_lan"
  }
}

public struct UserProfile: Decodable, Sendable, Hashable {
  public let loginName: String
  public let displayName: String?
  public let avatarURL: String?

  enum CodingKeys: String, CodingKey {
    case loginName = "login_name"
    case displayName = "display_name"
    case avatarURL = "avatar_url"
  }
}

/// This node's standing under tailnet lock. Keys are public: the node key and
/// tailnet-lock key an admin needs to sign this node from a trusted device.
public struct TailnetLock: Decodable, Sendable, Hashable {
  public let enabled: Bool
  public let signed: Bool
  public let lockedOut: Bool
  public let nodeKey: String?
  public let publicKey: String?
  public let signCommand: String?

  enum CodingKeys: String, CodingKey {
    case enabled, signed
    case lockedOut = "locked_out"
    case nodeKey = "node_key"
    case publicKey = "public_key"
    case signCommand = "sign_command"
  }
}

public struct ProfileStatus: Decodable, Sendable, Identifiable {
  public let profile: String
  public let displayName: String
  public let state: String
  public let selfName: String?
  public let deviceName: String?
  public let ips: [String]?
  public let peers: Int?
  public let authURL: String?
  public let suffixes: [String]?
  public let httpProxy: String?
  public let socks5Proxy: String?
  public let error: String?

  public let tailnet: String?
  public let magicDNSSuffix: String?
  public let suffixConflict: String?
  public let user: UserProfile?
  public let keyExpiry: String?
  public let connectedSince: String?
  public let healthMessages: [String]?
  public let adminURL: String?
  public var prefs: ProfilePrefs?
  /// The one profile whose exit node public traffic uses; the same on every
  /// status, since a host has a single default route.
  public let exitProfile: String?
  public let exitNodeOptions: [ExitNodeOption]?
  public let devices: [Device]?
  public let tailnetLock: TailnetLock?

  enum CodingKeys: String, CodingKey {
    case profile
    case displayName = "display_name"
    case state
    case selfName = "self"
    case deviceName = "device_name"
    case ips
    case peers
    case authURL = "auth_url"
    case suffixes
    case httpProxy = "http_proxy"
    case socks5Proxy = "socks5_proxy"
    case error
    case tailnet
    case magicDNSSuffix = "magic_dns_suffix"
    case suffixConflict = "suffix_conflict"
    case user
    case keyExpiry = "key_expiry"
    case connectedSince = "connected_since"
    case healthMessages = "health"
    case adminURL = "admin_url"
    case prefs
    case exitProfile = "exit_profile"
    case exitNodeOptions = "exit_node_options"
    case devices
    case tailnetLock = "tailnet_lock"
  }

  public var id: String { profile }

  public enum Condition: Sendable, CaseIterable {
    // lockedOut: logged in and Running, but tailnet lock hides every peer until
    // an admin signs this node.
    case running, starting, needsLogin, needsApproval, lockedOut, stopped, failed

    /// Signed in and up, whether or not tailnet lock lets it reach anything.
    public var isUp: Bool {
      switch self {
      case .running, .lockedOut: return true
      case .starting, .needsLogin, .needsApproval, .stopped, .failed: return false
      }
    }
  }

  public var condition: Condition {
    if let e = error, !e.isEmpty { return .failed }
    switch state {
    case "Running": return tailnetLock?.lockedOut == true ? .lockedOut : .running
    case "Starting": return .starting
    case "NeedsLogin":
      // An already-authenticated node reports NeedsLogin on every daemon start
      // until its saved state loads, and a brand-new one sits here for ~25s
      // before the control server issues a link. Neither is the user's problem
      // to act on, so only an actual link means "needs login".
      return authURL?.isEmpty == false ? .needsLogin : .starting
    case "NeedsMachineAuth": return .needsApproval
    default: return .stopped
    }
  }

  /// The node is up, whether or not tailnet lock lets it reach anything — what
  /// a connect switch reflects, as opposed to whether the tailnet is healthy.
  public var isUp: Bool { condition.isUp }

  public var name: String { displayName.isEmpty ? profile : displayName }

  /// How long this tailnet has been connected, compactly. Nil when it isn't —
  /// a tailnet that is down has no uptime, and "0s" would imply otherwise.
  public var uptime: String? {
    guard let raw = connectedSince, !raw.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let since = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    guard let since else { return nil }
    let secs = max(0, Int(Date().timeIntervalSince(since)))
    switch secs {
    case ..<60: return "\(secs)s"
    case ..<3600: return "\(secs / 60)m"
    case ..<86400:
      let h = secs / 3600
      let m = (secs % 3600) / 60
      return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    default:
      let d = secs / 86400
      let h = (secs % 86400) / 3600
      return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }
  }

  /// A configured-but-not-yet-reported tailnet. The config is the truth about
  /// which tailnets exist; the daemon is only the truth about how they are
  /// doing. Without this the UI claims you have none while it is starting.
  public static func placeholder(_ p: Profile) -> ProfileStatus {
    ProfileStatus(
      profile: p.name, displayName: p.displayName, state: "Stopped",
      selfName: nil, deviceName: p.hostname, ips: nil, peers: 0, authURL: nil,
      suffixes: p.suffixes, httpProxy: p.httpProxyPort == 0 ? nil : "127.0.0.1:\(p.httpProxyPort)",
      socks5Proxy: p.socks5ProxyPort == 0 ? nil : "127.0.0.1:\(p.socks5ProxyPort)", error: nil,
      tailnet: nil, magicDNSSuffix: nil, suffixConflict: nil, user: nil,
      keyExpiry: nil, connectedSince: nil, healthMessages: nil, adminURL: nil, prefs: nil,
      exitProfile: nil, exitNodeOptions: nil, devices: nil, tailnetLock: nil)
  }

  /// `self` keeps the wire's trailing dot; nothing user-facing wants it.
  public var machineName: String? {
    guard let n = selfName, !n.isEmpty else { return nil }
    return n.hasSuffix(".") ? String(n.dropLast()) : n
  }

  public var expiryDate: Date? {
    guard let s = keyExpiry, !s.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: s)
  }

  /// Days until the node key expires. nil when the key does not expire at all
  /// — a tagged device, or one with key expiry disabled — and nil while the
  /// node is not running, because a stopped node has reported nothing yet and
  /// "no date" must not read as "never".
  public var daysUntilExpiry: Int? {
    guard isUp, let d = expiryDate else { return nil }
    return Calendar.current.dateComponents([.day], from: Date(), to: d).day
  }

  /// The tailnet whose exit node is used instead of the one picked here, or
  /// nil when this pick is the one in use (or nothing is picked).
  public func exitNodeOverride(among all: [ProfileStatus]) -> String? {
    guard let picked = prefs?.exitNode, !picked.isEmpty,
      let winner = exitProfile, !winner.isEmpty, winner != profile
    else { return nil }
    return all.first { $0.profile == winner }?.name ?? winner
  }

  /// Suffixes beyond the one learned from the tailnet itself.
  public var extraSuffixes: [String] {
    let learned = magicDNSSuffix.map { "." + $0.lowercased() } ?? ""
    return (suffixes ?? []).filter { $0.lowercased() != learned }
  }
}

public struct Profile: Decodable, Sendable, Identifiable {
  public let name: String
  public let displayName: String
  public let hostname: String
  public let controlURL: String
  public let acceptRoutes: Bool
  public let suffixes: [String]?
  public let matchRoot: Bool
  public let ipRoutes: [String]?
  public let httpProxyPort: Int
  public let socks5ProxyPort: Int

  enum CodingKeys: String, CodingKey {
    case name
    case displayName = "display_name"
    case hostname
    case controlURL = "control_url"
    case acceptRoutes = "accept_routes"
    case suffixes
    case matchRoot = "match_root"
    case ipRoutes = "ip_routes"
    case httpProxyPort = "http_proxy_port"
    case socks5ProxyPort = "socks5_proxy_port"
  }

  /// A tailnet known only by name, before anything has reported its config.
  public init(name: String, displayName: String) {
    self.name = name
    self.displayName = displayName
    hostname = ""
    controlURL = ""
    acceptRoutes = false
    suffixes = nil
    matchRoot = false
    ipRoutes = nil
    httpProxyPort = 0
    socks5ProxyPort = 0
  }

  public var id: String { name }
}

public struct DeviceGroup: Sendable, Identifiable {
  public let name: String
  public let devices: [Device]
  public var id: String { name }
}

/// People first, then tags, each alphabetical; within a group the reachable
/// devices come first, since those are the ones you can act on.
public func deviceGroups(_ devices: [Device]) -> [DeviceGroup] {
  let groups = Dictionary(grouping: devices, by: \.group)
  let ordered = groups.keys.sorted { a, b in
    let at = a.hasPrefix("tag:")
    let bt = b.hasPrefix("tag:")
    return at == bt ? a.localizedStandardCompare(b) == .orderedAscending : !at
  }
  return ordered.map { key in
    DeviceGroup(
      name: key,
      devices: (groups[key] ?? []).sorted {
        $0.online == $1.online
          ? $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
          : $0.online
      })
  }
}

public enum Slug {
  /// The config key derived from a display name. `nameRE` on the Go side needs
  /// at least two characters, hence the `-1` tail on a single-character result.
  public static func key(_ display: String) -> String {
    let folded = display.folding(
      options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
    var out = ""
    for scalar in folded.unicodeScalars {
      let ch = Character(scalar)
      if scalar.isASCII, ch.isLetter || ch.isNumber {
        out.append(ch)
      } else if !out.isEmpty, !out.hasSuffix("-") {
        out.append("-")
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    if out.count > 32 {
      out = String(out.prefix(32))
      while out.hasSuffix("-") { out.removeLast() }
    }
    if out.count == 1 { out += "-1" }
    return out
  }

  /// `work` → `work-2` → `work-3`; only the key moves, never the display name.
  public static func bump(_ key: String) -> String {
    guard let dash = key.lastIndex(of: "-"), let n = Int(key[key.index(after: dash)...]) else {
      return key + "-2"
    }
    return key[..<dash] + "-\(n + 1)"
  }

  /// The tailnet's own name as sign-in reported it, else its MagicDNS suffix.
  public static func suggestedName(tailnet: String?, magicDNSSuffix: String?) -> String {
    [tailnet, magicDNSSuffix].compactMap { $0 }.first { !$0.isEmpty } ?? ""
  }

  public static func selfCheck() -> Bool {
    key("Work") == "work" && key("My Tailnet!") == "my-tailnet" && key("Café") == "cafe"
      && key("🎉") == "" && key("X") == "x-1" && bump("work") == "work-2"
      && bump("work-2") == "work-3"
  }
}

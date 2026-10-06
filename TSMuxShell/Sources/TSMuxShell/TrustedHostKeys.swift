import Foundation

/// Host keys the user accepted for hosts that don't advertise one through the
/// tailnet (plain OpenSSH rather than Tailscale SSH). Keyed by tailnet and
/// host, so the same name in two tailnets never shares a key.
public enum TrustedHostKeys {
  private static let prefix = "sshTrustedHostKey."

  public static func key(tailnet: String, host: String, defaults: UserDefaults = .standard)
    -> String?
  {
    defaults.string(forKey: prefix + tailnet + "/" + host)
  }

  public static func trust(
    _ key: String, tailnet: String, host: String, defaults: UserDefaults = .standard
  ) {
    defaults.set(key, forKey: prefix + tailnet + "/" + host)
  }

  public static func forget(tailnet: String, host: String, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: prefix + tailnet + "/" + host)
  }
}

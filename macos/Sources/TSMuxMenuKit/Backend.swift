import Foundation
import TSMuxKit

/// What runs the tailnets. The DMG app drives the `tsmux` daemon through its
/// CLI; the App Store app drives its own packet tunnel. The menu and Settings
/// window are the same for both and only ask this.
@MainActor
public protocol Backend: AnyObject {
  var features: BackendFeatures { get }
  /// Called when the service starts, stops or fails in a way the next status
  /// poll would not otherwise show at once.
  var onChange: (() -> Void)? { get set }

  /// False when there is nothing to drive at all (no CLI to run).
  var isAvailable: Bool { get }
  var isStarting: Bool { get }
  /// The last thing it said before it stopped without being asked to.
  var crashLine: String? { get }
  /// Whether the service that is up is ours to stop.
  var ownsService: Bool { get }
  /// The file "Edit config.yaml…" opens, if the user can edit one.
  var configFile: URL? { get }

  func start()
  func stop()
  func stopAndWait() async
  func shutdown()
  /// Each poll's result, so starting can end or time out.
  func observe(_ status: StatusResult)

  func status() async -> StatusResult
  /// The configured tailnets, cheaply and without starting anything.
  func profileList() -> Result<[Profile], CLIError>
  func setPrefs(_ change: PrefsChange) async -> Result<ProfileStatus, CLIError>
  func logout(_ profile: String) async -> Result<ProfileStatus, CLIError>
  func addProfile(_ key: String, displayName: String, controlURL: String?, matchRoot: Bool) async
    -> Result<Void, CLIError>
  func renameProfile(_ key: String, to newKey: String, displayName: String) async
    -> Result<Void, CLIError>
  func removeProfile(_ key: String, purge: Bool) async -> Result<RemovedProfile, CLIError>
  /// Puts a tailnet at `index` in the list, 0 being first.
  func moveProfile(_ key: String, to index: Int) async -> Result<Void, CLIError>
  func setHostname(_ key: String, _ name: String) async -> Result<Void, CLIError>
  func doctor() async -> Result<DoctorReport, CLIError>
  func version() async -> VersionInfo?
  func pacURL() async -> String?
  func applyPAC() async -> CLIError?
  /// Synchronous: quitting has to put the system proxy back before it exits.
  func restorePAC() -> CLIError?

  var expiryWatchInstalled: Bool { get }
  func setExpiryWatch(_ on: Bool) throws
  func checkExpiryNow()
}

/// What a backend can do beyond running tailnets. The UI leaves out what is
/// missing rather than showing it disabled.
public struct BackendFeatures: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Turning the system proxy on and off, and the PAC URL that goes with it.
  public static let pacToggle = BackendFeatures(rawValue: 1 << 0)
  public static let diagnostics = BackendFeatures(rawValue: 1 << 1)
  public static let cliIntegration = BackendFeatures(rawValue: 1 << 2)
  public static let expiryWatch = BackendFeatures(rawValue: 1 << 3)
  public static let renameDevice = BackendFeatures(rawValue: 1 << 4)
  /// Profiles can only change with the service stopped.
  public static let editsNeedRestart = BackendFeatures(rawValue: 1 << 5)
  public static let quitStopsService = BackendFeatures(rawValue: 1 << 6)
  /// Removing a tailnet can keep its saved login for next time.
  public static let keepLoginOnRemove = BackendFeatures(rawValue: 1 << 7)
  /// Runs as a system VPN profile, which On Demand keeps connected.
  public static let systemVPN = BackendFeatures(rawValue: 1 << 8)
}

/// "Check for Updates…", for a build that updates itself.
@MainActor
public protocol Updater: AnyObject {
  var canCheckForUpdates: Bool { get }
  func checkForUpdates()
}

public struct RemovedProfile: Decodable, Sendable {
  public let removed: String
  public let purged: Bool
  /// Set when a purge could not log the device out on its control server.
  public let warning: String?

  public init(removed: String, purged: Bool, warning: String?) {
    self.removed = removed
    self.purged = purged
    self.warning = warning
  }
}

public struct DoctorReport: Decodable, Sendable {
  public let config: String
  public let problems: [String]?
}

public struct VersionInfo: Decodable, Sendable {
  public let version: String?
  /// The tailscale.com the CLI was linked against, which is the thing that
  /// actually changes between most builds.
  public let tailscale: String?

  public init(version: String?, tailscale: String?) {
    self.version = version
    self.tailscale = tailscale
  }

  /// "0.1.0 (ts v1.102.5)". The bundle's own CFBundleShortVersionString stays a
  /// bare semver — Sparkle and Launch Services both parse it — so the pair only
  /// ever appears as display text.
  public var display: String {
    let app = version ?? "—"
    guard let ts = tailscale, !ts.isEmpty else { return app }
    return "\(app) (ts \(ts))"
  }
}

public struct CLIError: Error, Sendable {
  public let message: String
  public init(message: String) { self.message = message }
}

public enum StatusResult: Sendable {
  case ok([ProfileStatus])
  case daemonDown
  case failed(String)
}

public enum Expiry {
  /// Days of notice. Matches the CLI's own default, so the menu and the weekly
  /// notification agree about what "soon" means.
  public static let warnDays = 21
}

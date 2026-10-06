import Foundation
import NetworkExtension
import Observation
import TSMuxKit
import UserNotifications

/// The app's whole view of TSMux: the VPN configuration that hosts the tunnel
/// extension, and the tailnets the Go core inside it reports.
@Observable @MainActor
final class TunnelModel {
  private(set) var vpnStatus: NEVPNStatus = .invalid
  private(set) var tailnets: [ProfileStatus] = []
  var lastError: String?

  private var manager: NETunnelProviderManager?
  private var observer: (any NSObjectProtocol)?
  private var scheduledExpiries: [String: Date] = [:]

  var isConnected: Bool { vpnStatus == .connected }
  var isOn: Bool { [.connected, .connecting, .reasserting].contains(vpnStatus) }

  var statusText: String {
    switch vpnStatus {
    case .connected:
      let up = tailnets.filter { $0.condition == .running }.count
      return tailnets.isEmpty ? "On" : "On · \(up) of \(tailnets.count) tailnets connected"
    case .connecting, .reasserting: return "Connecting…"
    case .disconnecting: return "Disconnecting…"
    case .disconnected, .invalid: return "Off"
    @unknown default: return "Off"
    }
  }

  func tailnet(_ profile: String) -> ProfileStatus? { tailnets.first { $0.profile == profile } }

  func load() async {
    manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
    observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateStatus() }
    }
    updateStatus()
  }

  private func updateStatus() {
    vpnStatus = manager?.connection.status ?? .invalid
    if !isOn { tailnets = [] }
  }

  func setOn(_ on: Bool) async {
    guard on else {
      manager?.connection.stopVPNTunnel()
      return
    }
    do {
      try await start()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Installs the VPN configuration on first use, which is when iOS asks the
  /// user to allow it, then starts the tunnel and waits for it to come up.
  private func start() async throws {
    if isConnected { return }
    let m = manager ?? NETunnelProviderManager()
    if !m.isEnabled || m.protocolConfiguration == nil {
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
      proto.serverAddress = "Every tailnet at once"
      m.protocolConfiguration = proto
      m.localizedDescription = "TSMux"
      m.isEnabled = true
      try await m.saveToPreferences()
      // A freshly saved configuration can't start until it is loaded back.
      try await m.loadFromPreferences()
      manager = m
    }
    try m.connection.startVPNTunnel()
    for _ in 0..<60 where !isConnected {
      try await Task.sleep(for: .milliseconds(250))
      updateStatus()
    }
    guard isConnected else { throw TunnelError(message: "TSMux didn't connect. Try again.") }
  }

  private func send(_ req: TunnelRequest) async throws -> TunnelResponse {
    guard isConnected, let session = manager?.connection as? NETunnelProviderSession else {
      throw TunnelError(message: "TSMux is off.")
    }
    let data = try JSONEncoder().encode(req)
    let reply: Data? = try await withCheckedThrowingContinuation { c in
      do {
        try session.sendProviderMessage(data) { c.resume(returning: $0) }
      } catch {
        c.resume(throwing: error)
      }
    }
    guard let reply else { throw TunnelError(message: "The tunnel didn't answer.") }
    return try JSONDecoder().decode(TunnelResponse.self, from: reply)
  }

  func refresh() async {
    guard isConnected else { return }
    do {
      tailnets = try await send(.status).decode([ProfileStatus].self)
      await scheduleExpiryReminders()
    } catch {
      // A poll that fails mid-transition is not worth an alert; the next
      // one either succeeds or the VPN status explains why.
    }
  }

  /// Runs one change and reports its failure, so views stay one-liners.
  func perform(_ body: () async throws -> Void) async {
    do {
      try await body()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func setPrefs(_ change: PrefsChange) async {
    await perform {
      let fresh = try await send(.prefs(change)).decode(ProfileStatus.self)
      if let i = tailnets.firstIndex(where: { $0.profile == fresh.profile }) { tailnets[i] = fresh }
    }
  }

  func logout(_ profile: String) async {
    await perform {
      _ = try await send(.logout(profile)).decode(ProfileStatus.self)
      await refresh()
    }
  }

  /// Starts a tailnet under a placeholder key, turning TSMux on first if it
  /// isn't. Its real name is only known after sign-in; see `rename`.
  func add(controlURL: String) async throws -> String {
    try await start()
    var key = "new"
    while tailnet(key) != nil { key = Slug.bump(key) }
    _ = try await send(
      .addProfile(name: key, displayName: "New tailnet", controlURL: controlURL)
    ).decode([String: Bool].self)
    await refresh()
    return key
  }

  /// Gives a signed-in tailnet its name. Returns the key it now lives under.
  func rename(_ profile: String, to displayName: String) async throws -> String {
    var key = Slug.key(displayName)
    guard !key.isEmpty else { throw TunnelError(message: "Use letters or numbers in the name.") }
    while key != profile, tailnet(key) != nil { key = Slug.bump(key) }
    _ = try await send(.renameProfile(profile, to: key, displayName: displayName))
      .decode([String: Bool].self)
    await refresh()
    return key
  }

  func remove(_ profile: String) async {
    await perform {
      _ = try await send(.removeProfile(profile)).decode([String: Bool].self)
      UNUserNotificationCenter.current().removePendingNotificationRequests(
        withIdentifiers: [expiryID(profile)])
      await refresh()
    }
  }

  // MARK: Key expiry

  /// A reminder a week before each tailnet's node key expires, rescheduled on
  /// every refresh so it tracks re-authentication. This replaces the macOS
  /// LaunchAgent: iOS has no background job to run a check from.
  private func scheduleExpiryReminders() async {
    let center = UNUserNotificationCenter.current()
    let expiries = tailnets.reduce(into: [String: Date]()) { $0[$1.profile] = $1.expiryDate }
    guard expiries != scheduledExpiries else { return }
    scheduledExpiries = expiries
    let due = tailnets.compactMap { t -> (ProfileStatus, Date)? in
      guard let exp = t.expiryDate else { return nil }
      let at = exp.addingTimeInterval(-7 * 86400)
      return at > .now ? (t, at) : nil
    }
    guard !due.isEmpty,
      (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    else { return }
    for (t, at) in due {
      let content = UNMutableNotificationContent()
      content.title = "\(t.name) needs signing in soon"
      content.body = "Its key expires in a week. Open TSMux and sign in again to stay connected."
      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: at.timeIntervalSinceNow, repeats: false)
      try? await center.add(
        UNNotificationRequest(identifier: expiryID(t.profile), content: content, trigger: trigger))
    }
  }

  private func expiryID(_ profile: String) -> String { "expiry-\(profile)" }
}

import AppKit
import Foundation
import Observation
import TSMuxKit

// ponytail: one shared AppModel, no view-model-per-tab.

public enum UIState: Sendable {
  case cliMissing
  case down
  case starting
  case crashed(String)
  case failed(String)
  case ok([ProfileStatus])
}

public enum ConfigState: Sendable, Equatable {
  case firstRun
  case configured
  case broken(String)
}

enum SettingsTab: String, Sendable, CaseIterable {
  case accounts, settings, about

  var title: String {
    switch self {
    case .accounts: return "Accounts"
    case .settings: return "Settings"
    case .about: return "About"
    }
  }
}

@MainActor @Observable
public final class AppModel {
  @ObservationIgnored public let backend: any Backend
  var status: StatusResult = .daemonDown
  /// `profile list` — the YAML view. Needed for fields `/status` does not
  /// carry (match_root), and as the launch probe.
  var configProfiles: [Profile] = []

  /// What the UI lists. Falls back to the configured tailnets whenever the
  /// daemon has not reported yet, so "no tailnets" means the config is empty
  /// and never "the daemon is still starting".
  var displayProfiles: [ProfileStatus] {
    profiles.isEmpty ? configProfiles.map(ProfileStatus.placeholder) : profiles
  }
  public private(set) var configState: ConfigState = .configured

  var selectedTab: SettingsTab = .accounts
  var selectedProfile: String?
  /// Set by the menu's add-a-tailnet rows, consumed by the Accounts tab's sheet
  /// once the Settings window is up.
  var pendingAdd = false
  /// Bumped after any mutation so open sheets can re-read `profile list`.
  var profilesRevision = 0

  private var refreshing = false
  private var pacConfirmed = false
  /// Session-scoped by design: a fresh launch is a fresh statement of intent.
  private var stopLatch = false

  @ObservationIgnored var onChange: (() -> Void)?

  public init(backend: any Backend) {
    self.backend = backend
    backend.onChange = { [weak self] in
      self?.notify()
      self?.refresh()
    }
  }

  var features: BackendFeatures { backend.features }

  // MARK: defaults

  static let pacKey = "pacApplied"
  static let pacAutoKey = "pacAuto"
  static let alwaysCountKey = "alwaysShowCount"
  static let hideDockKey = "hideDockIcon"
  static let connectAtLaunchKey = "connectAtLaunch"
  public static let didShowFirstRunKey = "didShowFirstRun"

  var pacApplied: Bool {
    get { UserDefaults.standard.bool(forKey: Self.pacKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.pacKey)
      notify()
    }
  }

  var hideDockIcon: Bool {
    get { UserDefaults.standard.bool(forKey: Self.hideDockKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.hideDockKey)
      notify()
    }
  }

  var connectAtLaunch: Bool {
    get { UserDefaults.standard.object(forKey: Self.connectAtLaunchKey) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.connectAtLaunchKey)
      notify()
    }
  }

  // MARK: derived

  var ui: UIState {
    if !backend.isAvailable { return .cliMissing }
    if backend.isStarting { return .starting }
    switch status {
    case .ok(let ps): return .ok(ps)
    case .failed(let m): return .failed(m)
    case .daemonDown: return backend.crashLine.map { .crashed($0) } ?? .down
    }
  }

  var profiles: [ProfileStatus] {
    if case .ok(let ps) = ui { return ps }
    return []
  }

  var weOwnDaemon: Bool { backend.ownsService }

  /// Tailnets whose node key is inside the warning window, soonest first. A
  /// lapsed key stops that tailnet working until someone signs in again, and
  /// nothing else in the UI says it is coming.
  var expiringProfiles: [ProfileStatus] {
    profiles
      .filter { ($0.daysUntilExpiry ?? Int.max) <= Expiry.warnDays }
      .sorted { ($0.daysUntilExpiry ?? 0) < ($1.daysUntilExpiry ?? 0) }
  }

  /// The weekly check, on or off. The LaunchAgent file is the state — there is
  /// no second copy in defaults to drift out of step with it.
  var expiryWatchEnabled: Bool {
    get { backend.expiryWatchInstalled }
    set {
      do {
        try backend.setExpiryWatch(newValue)
      } catch {
        Alert.show(
          newValue ? "Could not schedule the weekly check" : "Could not remove the weekly check",
          (error as? CLIError)?.message ?? error.localizedDescription)
      }
      notify()
    }
  }

  var daemonRunning: Bool {
    switch ui {
    case .ok, .starting: return true
    default: return false
    }
  }

  var selection: ProfileStatus? {
    let list = displayProfiles
    return list.first { $0.profile == selectedProfile } ?? list.first
  }

  // MARK: launch

  /// Synchronous and cheap — `profile list` never starts tsnet or binds a port.
  func launchProbe() async {
    reloadConfigProfiles()
    guard configState == .configured else { return }
    // A daemon already up (a terminal, or a second copy of the app) is adopted.
    if case .ok = await backend.status() {
      refresh()
      return
    }
    if connectAtLaunch { autoStart() }
  }

  func reloadConfigProfiles() {
    switch backend.profileList() {
    case .success(let list):
      configProfiles = list
      configState = list.isEmpty ? .firstRun : .configured
    case .failure(let e):
      configState = .broken(e.message)
    }
    notify()
  }

  private func autoStart() {
    guard !stopLatch else { return }
    start()
  }

  // MARK: refresh

  public func refresh() {
    guard backend.isAvailable, !refreshing else { return }
    refreshing = true
    Task {
      apply(await backend.status())
    }
  }

  private func apply(_ next: StatusResult) {
    refreshing = false
    status = next
    backend.observe(next)
    if case .ok(let ps) = next {
      // The product promise is that a tailnet name just resolves. Requiring a
      // menu click for that is the whole problem, so route by default once a
      // tailnet is actually up — and stop if the user ever turns it off.
      if features.contains(.pacToggle), pacAuto, !pacApplied,
        ps.contains(where: { $0.condition == .running })
      {
        applyPAC(auto: true)
      }
      if !expiringProfiles.isEmpty { noticeExpiry() }
    }
    notify()
  }

  private func notify() { onChange?() }

  static let expiryNoticeKey = "lastExpiryNotice"

  /// At most one notification a day while the app is open. The menu row is the
  /// persistent reminder; a banner on every 5-second refresh would be noise.
  private func noticeExpiry() {
    let today = Calendar.current.startOfDay(for: Date())
    let last = UserDefaults.standard.object(forKey: Self.expiryNoticeKey) as? Date
    guard last == nil || last! < today else { return }
    UserDefaults.standard.set(Date(), forKey: Self.expiryNoticeKey)
    backend.checkExpiryNow()
  }

  // MARK: lifecycle

  func start() {
    stopLatch = false
    backend.start()
  }

  func stop() {
    stopLatch = true
    if pacApplied { restorePAC(silent: false) }
    backend.stop()
    finishStop()
  }

  /// The same, with the waiting off the main thread: it can take seconds, and
  /// the menu and every open sheet freeze for as long as it blocks.
  private func stopAsync() async {
    if pacApplied { restorePAC(silent: false) }
    await backend.stopAndWait()
    finishStop()
  }

  private func finishStop() {
    status = .daemonDown
    notify()
  }

  private var lastMutation: Task<Void, Never>?

  /// `profile add`/`rm` cannot run against a live daemon (D5), so bracket them
  /// when the backend says so. One at a time: a cancel pressed mid-add must
  /// not remove the profile before the add lands.
  @discardableResult
  func mutateProfiles<T: Sendable>(_ body: @escaping @MainActor (any Backend) async -> T) async
    -> T
  {
    let previous = lastMutation
    let task = Task {
      await previous?.value
      return await mutateNow(body)
    }
    lastMutation = Task { _ = await task.value }
    return await task.value
  }

  private func mutateNow<T: Sendable>(_ body: @escaping @MainActor (any Backend) async -> T)
    async -> T
  {
    // Any live daemon blocks the mutation, whether or not we started it.
    let restart = features.contains(.editsNeedRestart)
    let wasRunning = daemonRunning
    let countBefore = configProfiles.count
    if restart && wasRunning { await stopAsync() }
    let result = await body(backend)
    profilesRevision += 1
    reloadConfigProfiles()
    // Adding a tailnet is a fresh statement of intent; emptying the config is
    // the opposite — and `tsmux up` with zero profiles exits 1, which would
    // latch crashLine and report a crash the user caused by backing out.
    if configProfiles.count > countBefore {
      stopLatch = false
    } else if configProfiles.isEmpty {
      stopLatch = true
    }
    if restart, configState == .configured, wasRunning || !stopLatch { backend.start() }
    refresh()
    return result
  }

  /// A drag in the sidebar, in `onMove` terms: `destination` counts the row
  /// being moved, so moving down lands one before it.
  func moveProfile(from source: IndexSet, to destination: Int) {
    guard let from = source.first, displayProfiles.indices.contains(from) else { return }
    let key = displayProfiles[from].profile
    let to = destination > from ? destination - 1 : destination
    guard to != from else { return }
    // Shown at once: the tunnel restarts its tailnets to apply the order.
    if case .ok(var ps) = status {
      ps.move(fromOffsets: source, toOffset: destination)
      status = .ok(ps)
    }
    Task {
      if case .failure(let e) = await mutateProfiles({ await $0.moveProfile(key, to: to) }) {
        Alert.show("Could not reorder tailnets", e.message)
      }
    }
  }

  // MARK: PAC

  /// Off by hand means off: an automatic re-apply on the next poll would be
  /// the app arguing with the user.
  var pacAuto: Bool {
    get { (UserDefaults.standard.object(forKey: Self.pacAutoKey) as? Bool) ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.pacAutoKey) }
  }

  /// Off by default: the count only appears when a tailnet is not up.
  var alwaysShowCount: Bool {
    get { UserDefaults.standard.bool(forKey: Self.alwaysCountKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.alwaysCountKey)
      notify()
    }
  }

  func togglePAC() {
    if pacApplied {
      pacAuto = false
      restorePAC(silent: false)
      return
    }
    pacAuto = true
    if !pacConfirmed {
      let a = NSAlert()
      a.messageText = "Route system traffic through tsmux?"
      a.informativeText = "All system network traffic will be routed through tsmux."
      a.addButton(withTitle: "Route System Traffic")
      a.addButton(withTitle: "Cancel")
      NSApp.activate(ignoringOtherApps: true)
      guard a.runModal() == .alertFirstButtonReturn else { return }
      pacConfirmed = true
    }
    applyPAC(auto: false)
  }

  private func applyPAC(auto: Bool) {
    Task {
      if let err = await backend.applyPAC() {
        if !auto { Alert.show("Could not route system traffic", err.message) }
      } else {
        pacApplied = true
        notify()
      }
    }
  }

  func restorePAC(silent: Bool) {
    if let err = backend.restorePAC() {
      if !silent { Alert.show("Could not restore the system proxy", err.message) }
    } else {
      pacApplied = false
    }
  }

  // MARK: per-profile prefs

  /// Optimistic-then-authoritative: the change shows at once, then the status
  /// the backend hands back replaces it.
  @discardableResult
  func setPrefs(_ change: PrefsChange) async -> String? {
    if case .ok(var ps) = status, let i = ps.firstIndex(where: { $0.profile == change.profile }) {
      ps[i] = ps[i].applying(change)
      status = .ok(ps)
      notify()
    }
    switch await backend.setPrefs(change) {
    case .success(let fresh):
      replace(fresh)
      return nil
    case .failure(let e):
      refresh()
      return e.message
    }
  }

  @discardableResult
  func logout(_ profile: String) async -> String? {
    switch await backend.logout(profile) {
    case .success(let fresh):
      replace(fresh)
      return nil
    case .failure(let e):
      refresh()
      return e.message
    }
  }

  private func replace(_ fresh: ProfileStatus) {
    guard case .ok(var ps) = status else { return }
    if let i = ps.firstIndex(where: { $0.profile == fresh.profile }) {
      ps[i] = fresh
      status = .ok(ps)
      notify()
    }
  }

  func runDoctor() async {
    switch await backend.doctor() {
    case .success(let report):
      let problems = report.problems ?? []
      Alert.show(
        problems.isEmpty ? "No problems found" : "\(problems.count) problem(s) found",
        ([report.config] + problems).joined(separator: "\n\n"))
    case .failure(let e):
      Alert.show("Diagnostics failed", e.message)
    }
  }

  // MARK: shutdown

  func shutdown() {
    if pacApplied { restorePAC(silent: true) }
    backend.shutdown()
  }
}

public enum Alert {
  @MainActor
  public static func show(_ title: String, _ info: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
  }
}

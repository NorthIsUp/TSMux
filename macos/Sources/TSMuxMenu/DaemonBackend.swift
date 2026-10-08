import AppKit
import Foundation
import TSMuxKit
import TSMuxMenuKit

/// Runs the tailnets in a `tsmux up` daemon this app starts, or adopts one
/// started elsewhere, and does everything else through the CLI.
@MainActor
final class DaemonBackend: Backend {
  let features: BackendFeatures = [
    .pacToggle, .diagnostics, .cliIntegration, .expiryWatch, .renameDevice, .editsNeedRestart,
    .quitStopsService, .keepLoginOnRemove,
  ]
  var onChange: (() -> Void)?

  private var daemon: Process?
  private var daemonErr: Pipe?
  private var daemonLog: [String] = []
  private var expectingExit = false
  private var startDeadline: Date?
  private(set) var crashLine: String?

  var isAvailable: Bool { CLI.path != nil }
  var isStarting: Bool { startDeadline != nil }
  var ownsService: Bool { daemon?.isRunning == true }
  var configFile: URL? { ConfigPath.file }

  // MARK: lifecycle

  func start() {
    guard let exe = CLI.path, daemon?.isRunning != true else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["up"]
    p.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    p.standardError = errPipe
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      // EOF: the source otherwise fires forever on empty data and pegs a core.
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      guard let text = String(data: chunk, encoding: .utf8) else { return }
      Task { @MainActor in self.appendLog(text) }
    }
    p.terminationHandler = { proc in
      Task { @MainActor in self.daemonExited(status: proc.terminationStatus) }
    }
    do {
      try p.run()
    } catch {
      daemon = nil
      Alert.show("Could not start tsmux", (error as NSError).localizedDescription)
      return
    }
    daemon = p
    daemonErr = errPipe
    daemonLog.removeAll()
    crashLine = nil
    startDeadline = Date().addingTimeInterval(60)
    onChange?()
  }

  private func appendLog(_ text: String) {
    for line in text.split(separator: "\n") where !line.isEmpty {
      daemonLog.append(String(line))
    }
    if daemonLog.count > 200 { daemonLog.removeFirst(daemonLog.count - 200) }
  }

  private func daemonExited(status code: Int32) {
    daemon = nil
    startDeadline = nil
    daemonErr?.fileHandleForReading.readabilityHandler = nil
    daemonErr = nil
    if code != 0 && !expectingExit {
      crashLine = daemonLog.last ?? "tsmux exited with status \(code)"
    }
    expectingExit = false
    onChange?()
  }

  func observe(_ status: StatusResult) {
    if case .ok = status {
      startDeadline = nil
      crashLine = nil
    } else if let deadline = startDeadline, Date() > deadline {
      startDeadline = nil
      if crashLine == nil {
        crashLine = daemonLog.last ?? "tsmux did not come up within 60 seconds"
      }
    }
  }

  /// Stops whatever daemon is up, not just one we spawned: a daemon started
  /// from a terminal still holds the profiles, and refusing to act on it turns
  /// an ordinary "remove this tailnet" into an error the user cannot clear.
  func stop() {
    Self.awaitExit(beginStop())
  }

  func stopAndWait() async {
    let d = beginStop()
    await Task.detached { Self.awaitExit(d) }.value
  }

  /// Returns our daemon if it was running; nil means one from elsewhere, or none.
  private func beginStop() -> Process? {
    var ours: Process?
    if let d = daemon, d.isRunning {
      expectingExit = true
      d.terminate()
      ours = d
    }
    daemon = nil
    startDeadline = nil
    return ours
  }

  private nonisolated static func awaitExit(_ d: Process?) {
    if let d {
      let deadline = Date().addingTimeInterval(5)
      while d.isRunning && Date() < deadline { usleep(50_000) }
    } else {
      _ = CLI.run(["down"], timeout: 10)
    }
    // The process being gone is not the same as the port being free; the CLI
    // refuses to mutate while /status still answers.
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if case .daemonDown = CLI.status() { break }
      usleep(100_000)
    }
  }

  func shutdown() {
    guard let d = daemon, d.isRunning else { return }
    expectingExit = true
    d.terminate()
    let deadline = Date().addingTimeInterval(3)
    while d.isRunning && Date() < deadline { usleep(50_000) }
  }

  // MARK: calls

  func status() async -> StatusResult {
    await Task.detached(priority: .utility) { CLI.status() }.value
  }

  /// The launch probe: no tsnet, no ports, ~15ms, so it runs inline.
  func profileList() -> Result<[Profile], CLIError> {
    CLI.profileList()
  }

  func setPrefs(_ change: PrefsChange) async -> Result<ProfileStatus, CLIError> {
    let args = ["profile", "set", change.profile] + Self.flags(change)
    return await Task.detached { CLI.json(ProfileStatus.self, args, timeout: 15) }.value
  }

  private static func flags(_ c: PrefsChange) -> [String] {
    var f: [String] = []
    if let v = c.connected { f.append("--connected=\(v)") }
    if let v = c.acceptRoutes { f.append("--accept-routes=\(v)") }
    if let v = c.acceptDNS { f.append("--accept-dns=\(v)") }
    if let v = c.shieldsUp { f.append("--shields-up=\(v)") }
    if let v = c.exitNode { f += ["--exit-node", v] }
    if let v = c.exitNodeAllowLAN { f.append("--exit-node-lan=\(v)") }
    return f
  }

  func logout(_ profile: String) async -> Result<ProfileStatus, CLIError> {
    // With the daemon down this logs out from a short-lived node, which can
    // spend the full 15s logout timeout on an unreachable control server.
    await Task.detached {
      CLI.json(ProfileStatus.self, ["profile", "logout", profile], timeout: 40)
    }.value
  }

  func addProfile(_ key: String, displayName: String, controlURL: String?, matchRoot: Bool) async
    -> Result<Void, CLIError>
  {
    var args = ["profile", "add", key, "--display-name", displayName]
    if let controlURL { args += ["--control-url", controlURL] }
    if matchRoot { args.append("--match-root") }
    return await Task.detached { [args] in
      CLI.json(Profile.self, args, timeout: 20).map { _ in () }
    }.value
  }

  func renameProfile(_ key: String, to newKey: String, displayName: String) async
    -> Result<Void, CLIError>
  {
    await Self.run(
      ["--json", "profile", "rename", key, newKey, "--display-name", displayName], timeout: 20)
  }

  func removeProfile(_ key: String, purge: Bool) async -> Result<RemovedProfile, CLIError> {
    var args = ["profile", "rm", key]
    if purge { args.append("--purge") }
    // Purging logs out on the control server first, which can take up to 15s.
    return await Task.detached { [args] in
      CLI.json(RemovedProfile.self, args, timeout: 40)
    }.value
  }

  func setHostname(_ key: String, _ name: String) async -> Result<Void, CLIError> {
    await Self.run(["profile", "set", key, "--hostname", name], timeout: 4)
  }

  private static func run(_ args: [String], timeout: TimeInterval) async -> Result<Void, CLIError> {
    await Task.detached {
      let (_, err, code) = CLI.run(args, timeout: timeout)
      return code == 0 ? .success(()) : .failure(CLIError(message: CLI.message(err)))
    }.value
  }

  func doctor() async -> Result<DoctorReport, CLIError> {
    await Task.detached {
      let (data, err, code) = CLI.run(["--json", "doctor"], timeout: 30)
      // doctor exits 1 when it merely found problems, so read the JSON not the code.
      if let report = try? JSONDecoder().decode(DoctorReport.self, from: data) {
        return .success(report)
      }
      return .failure(
        CLIError(message: code == 0 ? "tsmux produced no report." : CLI.message(err)))
    }.value
  }

  func version() async -> VersionInfo? {
    await Task.detached { try? CLI.json(VersionInfo.self, ["version"]).get() }.value
  }

  func pacURL() async -> String? {
    await Task.detached { CLI.pacURL() }.value
  }

  /// No timeout: killing `pac apply` mid-loop leaves the system proxy
  /// half-applied with no restore snapshot.
  func applyPAC() async -> CLIError? {
    await Task.detached {
      let (_, err, code) = CLI.run(["pac", "apply"], timeout: nil)
      return code == 0 ? nil : CLIError(message: CLI.message(err))
    }.value
  }

  func restorePAC() -> CLIError? {
    let (_, err, code) = CLI.run(["pac", "restore"], timeout: nil)
    return code == 0 ? nil : CLIError(message: CLI.message(err))
  }

  // MARK: expiry

  var expiryWatchInstalled: Bool { ExpiryWatch.isInstalled }

  func setExpiryWatch(_ on: Bool) throws {
    try on ? ExpiryWatch.install() : ExpiryWatch.remove()
  }

  func checkExpiryNow() { ExpiryWatch.checkNow() }
}

enum ConfigPath {
  static var file: URL {
    let base =
      ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? ("~/.config" as NSString).expandingTildeInPath
    return URL(fileURLWithPath: base)
      .appendingPathComponent("tsmux")
      .appendingPathComponent("config.yaml")
  }
}

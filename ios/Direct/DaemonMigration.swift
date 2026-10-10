import Foundation

/// The DMG app up to 0.1.x ran the tailnets in a `tsmux up` daemon, could point
/// the system proxy at that daemon's PAC, and could install a LaunchAgent.
/// Sparkle updates those installs into this app, which uses none of it, so the
/// first launch undoes what is left. Its tailnets don't carry over: their login
/// state is in ~/.config/tsmux, which the sandboxed extension can't read.
enum DaemonMigration {
  private static let doneKey = "migratedFromDaemon"
  private static let agentLabel = "dev.northisup.tsmux.expiry"

  static func run() {
    guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
    UserDefaults.standard.set(true, forKey: doneKey)
    let agent = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    if FileManager.default.fileExists(atPath: agent.path) {
      exec("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
      try? FileManager.default.removeItem(at: agent)
    }
    guard FileManager.default.fileExists(atPath: ConfigDir.path),
      let cli = Bundle.main.url(forResource: "tsmux", withExtension: nil)?.path
    else { return }
    exec(cli, ["down"])
    exec(cli, ["pac", "restore"])
  }

  private enum ConfigDir {
    static var path: String {
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tsmux").path
    }
  }

  private static func exec(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
  }
}

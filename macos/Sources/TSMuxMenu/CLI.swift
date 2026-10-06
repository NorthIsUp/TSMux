import Foundation
import TSMuxKit

// Everything the GUI knows comes from `tsmux --json`, so the two stay in step
// without a second config parser. Swift never speaks HTTP to the daemon.

struct RemovedProfile: Decodable, Sendable {
  let removed: String
  let purged: Bool
}

struct DoctorReport: Decodable, Sendable {
  let config: String
  let problems: [String]?
}

struct VersionInfo: Decodable, Sendable {
  let version: String?
  /// The tailscale.com the CLI was linked against, which is the thing that
  /// actually changes between most builds.
  let tailscale: String?

  /// "0.1.0 (ts v1.102.5)". The bundle's own CFBundleShortVersionString stays a
  /// bare semver — Sparkle and Launch Services both parse it — so the pair only
  /// ever appears as display text.
  var display: String {
    let app = version ?? "—"
    guard let ts = tailscale, !ts.isEmpty else { return app }
    return "\(app) (ts \(ts))"
  }
}

/// The contract's whole error surface: stderr's last line, `tsmux: ` stripped.
struct CLIError: Error, Sendable {
  let message: String
}

enum StatusResult: Sendable {
  case ok([ProfileStatus])
  case daemonDown
  case failed(String)
}

// MARK: - Runner

enum CLI {
  /// Prefers the copy shipped inside the bundle so the app and the daemon are
  /// always the same build. No bare-name fallback: Finder's PATH lacks
  /// /opt/homebrew/bin, so it would only ever resolve to a confusing failure.
  static let path: String? = {
    if let bundled = Bundle.main.url(forResource: "tsmux", withExtension: nil)?.path,
      FileManager.default.isExecutableFile(atPath: bundled)
    {
      return bundled
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for candidate in ["/opt/homebrew/bin/tsmux", "/usr/local/bin/tsmux", "\(home)/go/bin/tsmux"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return nil
  }()

  @discardableResult
  /// `timeout: nil` for mutating subcommands (`pac apply`/`restore`): killing
  /// those mid-loop leaves the system proxy half-applied with no restore snapshot.
  static func run(_ args: [String], timeout: TimeInterval? = 4) -> (
    out: Data, err: String, status: Int32
  ) {
    guard let exe = path else { return (Data(), "tsmux CLI not found", -1) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
      try p.run()
    } catch {
      return (Data(), (error as NSError).description, -1)
    }
    // A wedged daemon must never wedge the app.
    if let timeout {
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
      }
    }

    let errQueue = DispatchQueue(label: "tsmux.stderr")
    var errData = Data()
    let done = DispatchSemaphore(value: 0)
    errQueue.async {
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      done.signal()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    done.wait()
    p.waitUntilExit()
    return (outData, String(data: errData, encoding: .utf8) ?? "", p.terminationStatus)
  }

  /// Contract: on failure stderr's last non-empty line is the message, prefixed `tsmux: `.
  static func message(_ err: String) -> String {
    let line =
      err.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last(where: { !$0.isEmpty }) ?? ""
    if line.isEmpty { return "tsmux reported no details." }
    return line.hasPrefix("tsmux: ") ? String(line.dropFirst("tsmux: ".count)) : line
  }

  static func json<T: Decodable>(
    _ type: T.Type, _ args: [String], timeout: TimeInterval? = 4
  ) -> Result<T, CLIError> {
    let (data, err, code) = run(["--json"] + args, timeout: timeout)
    guard code == 0 else { return .failure(CLIError(message: message(err))) }
    do {
      return .success(try JSONDecoder().decode(T.self, from: data))
    } catch {
      return .failure(
        CLIError(message: "unreadable output from tsmux: \(error.localizedDescription)"))
    }
  }

  static func status() -> StatusResult {
    let (data, err, code) = run(["--json", "status"])
    if code == 0 {
      do {
        return .ok(try JSONDecoder().decode([ProfileStatus].self, from: data))
      } catch {
        return .failed(error.localizedDescription)
      }
    }
    if err.contains("daemon is not running") { return .daemonDown }
    return .failed(message(err))
  }

  /// The launch probe: no tsnet, no ports, ~15ms. `[]` means first run.
  static func profileList() -> Result<[Profile], CLIError> {
    json([Profile].self, ["profile", "list"])
  }

  static func pacURL() -> String? {
    let (data, _, code) = run(["pac", "url"])
    guard code == 0 else { return nil }
    let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (s?.isEmpty == false) ? s : nil
  }
}

// MARK: - Profile key derivation

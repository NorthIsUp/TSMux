import Foundation
import Testing

@testable import TSMuxShell

/// A real OpenSSH server, run unprivileged on a spare loopback port: the whole
/// path from SSHConnection through the Go bridge to an actual sshd.
private final class LocalSSHD {
  let dir: URL
  let port: Int
  let hostKey: String
  let clientKey: String
  private let process = Process()

  init() throws {
    dir = FileManager.default.temporaryDirectory.appending(path: "tsmuxshell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["host", "client"] {
      try Self.run(
        "/usr/bin/ssh-keygen",
        ["-q", "-t", "ed25519", "-N", "", "-f", dir.appending(path: name).path])
    }
    try FileManager.default.copyItem(
      at: dir.appending(path: "client.pub"), to: dir.appending(path: "authorized_keys"))
    port = Int.random(in: 40000..<60000)
    let config = """
      Port \(port)
      ListenAddress 127.0.0.1
      HostKey \(dir.appending(path: "host").path)
      AuthorizedKeysFile \(dir.appending(path: "authorized_keys").path)
      PidFile \(dir.appending(path: "sshd.pid").path)
      StrictModes no
      UsePAM no
      PasswordAuthentication no
      """
    try config.write(to: dir.appending(path: "sshd_config"), atomically: true, encoding: .utf8)
    // Type and base64 only: the comment ssh-keygen appends isn't on the wire.
    hostKey = try String(contentsOf: dir.appending(path: "host.pub"), encoding: .utf8)
      .split(separator: " ").prefix(2).joined(separator: " ")
    clientKey = try String(contentsOf: dir.appending(path: "client"), encoding: .utf8)

    process.executableURL = URL(filePath: "/usr/sbin/sshd")
    process.arguments = ["-D", "-e", "-f", dir.appending(path: "sshd_config").path]
    process.standardError = FileHandle.nullDevice
    try process.run()
    Thread.sleep(forTimeInterval: 0.5)
  }

  deinit {
    process.terminate()
    try? FileManager.default.removeItem(at: dir)
  }

  private static func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(filePath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
  }
}

@MainActor
private func waitFor(
  _ connection: SSHConnection, _ done: (SSHState) -> Bool
) async throws -> SSHState {
  for _ in 0..<100 {
    if done(connection.state) { return connection.state }
    try await Task.sleep(for: .milliseconds(100))
  }
  Issue.record("timed out in phase \(connection.state.phase)")
  return connection.state
}

@Suite(.serialized) @MainActor struct SSHConnectionTests {
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")))
  func runsAShellAgainstRealSSHD() async throws {
    let sshd = try LocalSSHD()
    let user = NSUserName()
    let base = SSHRequest(socksAddr: "", host: "127.0.0.1", port: sshd.port, user: user)

    // Nothing vouches for the key yet: the user gets asked.
    let unknown = SSHConnection(base)
    unknown.start { _ in }
    let asked = try await waitFor(unknown) { $0.phase == .failed }
    #expect(asked.isUnknownHostKey)
    #expect(asked.hostKey == sshd.hostKey)
    #expect(asked.fingerprint?.hasPrefix("SHA256:") == true)

    // A pinned key that isn't the server's: refuse, don't ask.
    var wrong = base
    wrong.hostKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    ]
    let mismatch = SSHConnection(wrong)
    mismatch.start { _ in }
    #expect(try await waitFor(mismatch) { $0.phase == .failed }.isHostKeyMismatch)

    var good = base
    good.hostKeys = [sshd.hostKey]
    good.privateKey = sshd.clientKey
    let shell = SSHConnection(good)
    var output = ""
    shell.start { output += String(decoding: $0, as: UTF8.self) }
    _ = try await waitFor(shell) { $0.phase == .open }
    shell.resize(cols: 100, rows: 30)
    shell.send(Array("stty size; echo tsmux-$((6*7))\n".utf8))
    for _ in 0..<100 where !output.contains("tsmux-42") {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(output.contains("tsmux-42"))
    #expect(output.contains("30 100"))

    shell.send(Array("exit\n".utf8))
    _ = try await waitFor(shell) { $0.phase == .closed }
  }

  @Test func unreachableHostFails() async throws {
    let c = SSHConnection(SSHRequest(socksAddr: "", host: "127.0.0.1", port: 1, user: "x"))
    c.start { _ in }
    let s = try await waitFor(c) { $0.phase == .failed }
    #expect(s.error?.isEmpty == false)
    #expect(!s.isUnknownHostKey)
  }
}

@Suite struct SSHAccessTests {
  private func defaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "tsmuxshell-test-\(UUID().uuidString)"))
  }

  @Test func userIsTheLoginLocalPart() {
    #expect(SSHAccess.user(login: "adam@askclara.com") == "adam")
    #expect(SSHAccess.user(login: "adam") == "adam")
    #expect(SSHAccess.user(login: nil) == nil)
    #expect(SSHAccess.user(login: "@x") == nil)
  }

  @Test func offersOnlyOnlineTailscaleSSHMachines() throws {
    let d = try defaults()
    func target(
      online: Bool = true, keys: [String]? = ["ssh-ed25519 AAAA"], socks: String? = "127.0.0.1:1"
    )
      -> ShellTarget?
    {
      SSHAccess.target(
        device: "box.ts.net", ips: ["100.64.0.9"], online: online, hostKeys: keys, tailnet: "work",
        login: "adam@example.com", socksAddr: socks, defaults: d)
    }
    let t = try #require(target())
    #expect(t.user == "adam" && t.host == "100.64.0.9")
    #expect(target(online: false) == nil)
    #expect(target(keys: []) == nil)
    #expect(target(keys: nil) == nil)
    #expect(target(socks: nil) == nil)
  }

  @Test func aDenialHidesTheMachineForADay() throws {
    let d = try defaults()
    let now = Date(timeIntervalSince1970: 1_000_000)
    func target(at: Date) -> ShellTarget? {
      SSHAccess.target(
        device: "box.ts.net", ips: nil, online: true, hostKeys: ["k"], tailnet: "work",
        login: "adam@example.com", socksAddr: "127.0.0.1:1", defaults: d, now: at)
    }
    let t = try #require(target(at: now))
    SSHAccess.markDenied(t, defaults: d, now: now)
    #expect(target(at: now.addingTimeInterval(3600)) == nil)
    #expect(target(at: now.addingTimeInterval(SSHAccess.denialLifetime + 1)) != nil)
    // Scoped to the tailnet: the same name elsewhere is unaffected.
    #expect(
      SSHAccess.target(
        device: "box.ts.net", ips: nil, online: true, hostKeys: ["k"], tailnet: "home",
        login: "adam@example.com", socksAddr: "127.0.0.1:1", defaults: d, now: now) != nil)
  }
}

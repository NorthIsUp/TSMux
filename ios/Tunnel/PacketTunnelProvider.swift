import Foundation
import NetworkExtension
import Synchronization
import TSMuxCore
import TSMuxKit

/// Runs every tailnet in this one process. No packets flow through the tunnel:
/// it exists to keep the process alive and to carry the proxy settings, whose
/// PAC sends each tailnet's names to that tailnet's loopback proxy.
// The superclass isn't Sendable; this class's own state is all behind Mutex.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
  private let appliedPAC = Mutex("")
  private let pacWatch = Mutex<Task<Void, Never>?>(nil)

  nonisolated(nonsending) override func startTunnel(options: [String: NSObject]?) async throws {
    // The Developer ID system extension names its own, team-prefixed group:
    // a group.* one needs a profile that the API can't assign a group to.
    let group = Bundle.main.object(forInfoDictionaryKey: "TSMuxAppGroup") as? String ?? appGroupID
    guard
      let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { throw TunnelError(message: "app group container is missing") }
    try prepareStateDirectory(in: dir)
    if let err = dir.path.withCString({ TSMuxStart(UnsafeMutablePointer(mutating: $0)) }) {
      defer { TSMuxFree(err) }
      throw TunnelError(message: String(cString: err))
    }
    try await applySettings()
    // The PAC grows when a tailnet's DNS suffix is learned at login, and the
    // OS only reads it from the settings below.
    pacWatch.withLock {
      $0 = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5))
          try? await self?.applySettings()
        }
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    pacWatch.withLock { $0?.cancel() }
    TSMuxStop()
  }

  override func handleAppMessage(_ messageData: Data) async -> Data? {
    let reply = Self.call(String(decoding: messageData, as: UTF8.self))
    try? await applySettings()
    return Data(reply.utf8)
  }

  private func applySettings() async throws {
    let pac = try JSONDecoder().decode(
      TunnelResponse.self, from: Data(Self.call(try Self.encode(.pac)).utf8)
    ).body
    let changed = appliedPAC.withLock { applied in
      defer { applied = pac }
      return applied != pac
    }
    guard changed else { return }

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    // An address with no routes: the interface comes up, nothing is captured.
    settings.ipv4Settings = NEIPv4Settings(
      addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
    let proxy = NEProxySettings()
    proxy.autoProxyConfigurationEnabled = true
    proxy.proxyAutoConfigurationJavaScript = pac
    // With no routes claimed, iOS ignores proxy settings unless matchDomains
    // is set; "" is a suffix of every host, and the PAC sends the rest DIRECT
    // or, with an exit node in use, to that tailnet's proxy.
    // https://developer.apple.com/forums/thread/822733
    proxy.matchDomains = [""]
    settings.proxySettings = proxy
    do {
      try await setTunnelNetworkSettings(settings)
    } catch {
      appliedPAC.withLock { $0 = "" }
      throw error
    }
  }

  private static func encode(_ req: TunnelRequest) throws -> String {
    String(decoding: try JSONEncoder().encode(req), as: UTF8.self)
  }

  private static func call(_ request: String) -> String {
    guard let out = request.withCString({ TSMuxCall(UnsafeMutablePointer(mutating: $0)) }) else {
      return #"{"code":500,"body":"{\"error\":\"no reply from core\"}"}"#
    }
    defer { TSMuxFree(out) }
    return String(cString: out)
  }
}

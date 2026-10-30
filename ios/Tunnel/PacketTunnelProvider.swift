import Foundation
import NetworkExtension
import Synchronization
import TSMuxCore
import TSMuxKit

/// Runs every tailnet in this one process. The PAC sends each tailnet's names
/// to its loopback proxy, and the tunnel's routes and DNS carry everything
/// else bound for a tailnet, so tools that ignore proxies reach it too.
// The superclass isn't Sendable; this class's own state is all behind Mutex.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
  private let applied = Mutex("")
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
    // The utun exists once settings are first applied, and the core attaches
    // it once; until then, or after a failure, the next pass retries.
    defer {
      if let req = try? Self.encode(.attachTunnel) { _ = Self.call(req) }
    }
    let pac = try JSONDecoder().decode(
      TunnelResponse.self, from: Data(Self.call(try Self.encode(.pac)).utf8)
    ).body
    let tunnel = try JSONDecoder().decode(
      TunnelResponse.self, from: Data(Self.call(try Self.encode(.tunnel)).utf8)
    ).decode(TunnelSettings.self)
    let key = pac + String(decoding: try JSONEncoder().encode(tunnel), as: UTF8.self)
    let changed = applied.withLock { applied in
      defer { applied = key }
      return applied != key
    }
    guard changed else { return }

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let ipv4 = NEIPv4Settings(addresses: [tunnel.address], subnetMasks: ["255.255.255.255"])
    ipv4.includedRoutes = tunnel.routes.map {
      NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask)
    }
    settings.ipv4Settings = ipv4
    // With no domains, a DNS server here would take every query on the system.
    if !tunnel.matchDomains.isEmpty {
      let dns = NEDNSSettings(servers: [tunnel.dnsServer])
      dns.matchDomains = tunnel.matchDomains
      settings.dnsSettings = dns
    }
    let proxy = NEProxySettings()
    proxy.autoProxyConfigurationEnabled = true
    #if os(macOS)
      // By URL, the way `tsmux pac apply` did: Chromium reads only a PAC URL,
      // and Safari never sent requests the inline script routed to a proxy.
      // The query changes with the script, so the OS refetches it.
      if let url = Self.pacURL(version: pac) {
        proxy.proxyAutoConfigurationURL = url
      } else {
        proxy.proxyAutoConfigurationJavaScript = pac
      }
    #else
      proxy.proxyAutoConfigurationJavaScript = pac
    #endif
    // The routes claim only tailnet ranges, and iOS ignores proxy settings
    // for the rest unless matchDomains is set; "" is a suffix of every host, and the PAC sends the rest DIRECT
    // or, with an exit node in use, to that tailnet's proxy.
    // https://developer.apple.com/forums/thread/822733
    proxy.matchDomains = [""]
    settings.proxySettings = proxy
    do {
      try await setTunnelNetworkSettings(settings)
    } catch {
      applied.withLock { $0 = "" }
      throw error
    }
  }

  /// The core's loopback PAC, which only the Mac serves.
  private static func pacURL(version pac: String) -> URL? {
    guard
      let ep = try? JSONDecoder().decode(
        TunnelResponse.self, from: Data(call(try encode(.cli)).utf8)
      ).decode(CLIEndpoint.self)
    else { return nil }
    let v = String(UInt(bitPattern: pac.hashValue), radix: 36)
    return URL(string: "\(ep.url)/proxy.pac?v=\(v)")
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

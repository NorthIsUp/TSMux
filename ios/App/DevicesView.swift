import SwiftUI
import TSMuxKit
import TSMuxShell

struct DevicesView: View {
  let profile: String
  @Environment(TunnelModel.self) private var model
  @State private var query = ""
  @State private var shell: ShellTarget?

  var body: some View {
    List {
      if !services.isEmpty {
        Section("Services") {
          ForEach(services) { s in
            ServiceRow(service: s, route: route(s.name, s.routed, s.routedBy))
          }
        }
      }
      ForEach(deviceGroups(filtered)) { g in
        Section(g.name) {
          ForEach(g.devices) { d in
            let target = shellTarget(d)
            DeviceRow(
              device: d, openShell: target.map { t in { shell = t } },
              route: route(d.name, d.routed, d.routedBy)
            )
            .swipeActions {
              if let target {
                Button("Shell", systemImage: "terminal") { shell = target }.tint(.indigo)
              }
            }
          }
        }
      }
    }
    .navigationTitle("Devices")
    .searchable(text: $query)
    .navigationDestination(item: $shell) { ShellScreen(target: $0) }
  }

  /// Only Tailscale SSH machines get a shell; see SSHAccess.
  private func shellTarget(_ d: Device) -> ShellTarget? {
    let t = model.tailnet(profile)
    return SSHAccess.target(
      device: d.name, ips: d.ips, online: d.online, hostKeys: d.sshHostKeys, tailnet: profile,
      login: t?.user?.loginName, socksAddr: t?.socks5Proxy)
  }

  private func route(_ name: String, _ routed: Bool?, _ other: String?) -> RouteSwitch {
    RouteSwitch(on: routed == true, blockedBy: routed == true ? nil : other) { on in
      Task { await model.routeIP(profile, name, on: on) }
    }
  }

  private var services: [Service] {
    let all = model.tailnet(profile)?.services ?? []
    guard !query.isEmpty else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private var filtered: [Device] {
    let all = model.tailnet(profile)?.devices ?? []
    guard !query.isEmpty else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }
}

/// "Route this IP address": off by default, since a 100.x address is a
/// different machine in each tailnet.
@MainActor struct RouteSwitch {
  let on: Bool
  /// The tailnet that already routes this address.
  let blockedBy: String?
  let set: (Bool) -> Void

  @ViewBuilder var menuItem: some View {
    if let other = blockedBy {
      Text("IP already routed to \(other)")
    } else {
      Toggle(
        "Route this IP address", systemImage: "arrow.triangle.branch",
        isOn: Binding(get: { on }, set: set))
    }
  }

  @ViewBuilder var swipeButton: some View {
    if blockedBy == nil {
      Button(on ? "Stop routing" : "Route IP", systemImage: "arrow.triangle.branch") { set(!on) }
        .tint(on ? .gray : .blue)
    }
  }

  @ViewBuilder var badge: some View {
    if on {
      Image(systemName: "arrow.triangle.branch")
        .font(.caption)
        .foregroundStyle(.blue)
        .accessibilityLabel("IP address routed")
    }
  }
}

private struct ServiceRow: View {
  let service: Service
  let route: RouteSwitch

  var body: some View {
    Button {
      if let n = service.dnsName { Pasteboard.copy("https://\(n)") }
    } label: {
      HStack {
        Text(service.shortName).foregroundStyle(.primary)
        route.badge
        Spacer()
        Text(route.blockedBy.map { "routed to \($0)" } ?? service.ips?.first ?? "")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions(edge: .leading) { route.swipeButton }
    .contextMenu {
      route.menuItem
      if let n = service.dnsName {
        Button("Copy URL", systemImage: "link") { Pasteboard.copy("https://\(n)") }
      }
      if let ip = service.ips?.first {
        Button("Copy IP", systemImage: "number") { Pasteboard.copy(ip) }
      }
    }
  }
}

/// A tap copies the URL, the thing you paste into a browser; the menu has the
/// IP and the short name, like ⌥ and ⌥⇧ in the macOS menu.
private struct DeviceRow: View {
  let device: Device
  let openShell: (() -> Void)?
  let route: RouteSwitch
  @State private var copied = false

  var body: some View {
    Button {
      copy(device.url)
    } label: {
      HStack {
        Circle().fill(device.online ? .green : .gray.opacity(0.4)).frame(width: 8, height: 8)
        VStack(alignment: .leading) {
          HStack(spacing: 6) {
            Text(device.shortName).foregroundStyle(.primary)
            if openShell != nil {
              Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.indigo)
                .accessibilityLabel("SSH available")
            }
            route.badge
          }
          if let os = device.os, !os.isEmpty {
            Text(os).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Text(copied ? "Copied" : device.primaryIP ?? "")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions(edge: .leading) { route.swipeButton }
    .contextMenu {
      route.menuItem
      Button("Copy URL", systemImage: "link") { copy(device.url) }
      if let ip = device.primaryIP {
        Button("Copy IP", systemImage: "number") { copy(ip) }
      }
      Button("Copy name", systemImage: "textformat") { copy(device.shortName) }
      if let openShell {
        Button("Open Shell", systemImage: "terminal", action: openShell)
      }
      if let url = URL(string: device.url) {
        Link(destination: url) { Label("Open in Safari", systemImage: "safari") }
      }
    }
  }

  private func copy(_ s: String) {
    Pasteboard.copy(s)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

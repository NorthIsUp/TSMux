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
      ForEach(deviceGroups(filtered)) { g in
        Section(g.name) {
          ForEach(g.devices) { d in
            let target = shellTarget(d)
            DeviceRow(device: d, openShell: target.map { t in { shell = t } })
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

  private var filtered: [Device] {
    let all = model.tailnet(profile)?.devices ?? []
    guard !query.isEmpty else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }
}

/// A tap copies the URL, the thing you paste into a browser; the menu has the
/// IP and the short name, like ⌥ and ⌥⇧ in the macOS menu.
private struct DeviceRow: View {
  let device: Device
  let openShell: (() -> Void)?
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
    .contextMenu {
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

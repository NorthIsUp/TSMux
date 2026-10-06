import SwiftUI
import TSMuxKit
import UIKit

struct DevicesView: View {
  let profile: String
  @Environment(TunnelModel.self) private var model
  @State private var query = ""

  var body: some View {
    List {
      ForEach(deviceGroups(filtered)) { g in
        Section(g.name) {
          ForEach(g.devices) { DeviceRow(device: $0) }
        }
      }
    }
    .navigationTitle("Devices")
    .searchable(text: $query)
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
  @State private var copied = false

  var body: some View {
    Button {
      copy(device.url)
    } label: {
      HStack {
        Circle().fill(device.online ? .green : .gray.opacity(0.4)).frame(width: 8, height: 8)
        VStack(alignment: .leading) {
          Text(device.shortName).foregroundStyle(.primary)
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
      if let url = URL(string: device.url) {
        Link(destination: url) { Label("Open in Safari", systemImage: "safari") }
      }
    }
  }

  private func copy(_ s: String) {
    UIPasteboard.general.string = s
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

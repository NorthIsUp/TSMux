import SwiftUI
import TSMuxKit

@main
struct TSMuxApp: App {
  @State private var model = TunnelModel()

  var body: some Scene {
    WindowGroup {
      ContentView().environment(model)
    }
  }
}

struct ContentView: View {
  @Environment(TunnelModel.self) private var model
  @Environment(\.scenePhase) private var phase
  @State private var adding = false
  @State private var path: [String] = []

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          Toggle(
            isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } })
          ) {
            VStack(alignment: .leading) {
              Text("TSMux")
              Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            }
          }
        } footer: {
          Text(
            "Safari and apps that use the system proxy reach every tailnet's names. Everything else goes out normally."
          )
        }

        if model.isConnected && !model.tailnets.isEmpty {
          Section("Tailnets") {
            ForEach(model.tailnets) { t in
              NavigationLink(value: t.profile) { TailnetRow(tailnet: t) }
            }
          }
        } else if model.isConnected || !model.isOn {
          Section {
            Button("Set up your first tailnet…", systemImage: "plus.circle") { adding = true }
          }
        }
      }
      .navigationTitle("TSMux")
      .navigationDestination(for: String.self) { TailnetView(profile: $0) }
      .toolbar {
        Button("Add tailnet", systemImage: "plus") { adding = true }
      }
      .sheet(isPresented: $adding) { AddTailnetView { path = [$0] } }
      .alert(
        "Something went wrong",
        isPresented: Binding(
          get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } }),
        actions: {}, message: { Text(model.lastError ?? "") }
      )
      .task { await model.load() }
      .task(id: model.isConnected && phase == .active) {
        guard model.isConnected && phase == .active else { return }
        while !Task.isCancelled {
          await model.refresh()
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }
  }
}

struct TailnetRow: View {
  let tailnet: ProfileStatus

  var body: some View {
    HStack(spacing: 12) {
      if tailnet.condition == .starting {
        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
      } else {
        Circle().fill(color).frame(width: 10, height: 10)
      }
      VStack(alignment: .leading) {
        Text(tailnet.name)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var color: Color {
    switch tailnet.condition {
    case .running: .green
    case .starting: .yellow
    case .needsLogin, .needsApproval, .lockedOut: .orange
    case .stopped: .gray
    case .failed: .red
    }
  }

  private var subtitle: String {
    switch tailnet.condition {
    case .running:
      let devices = "\(tailnet.peers ?? 0) devices"
      return tailnet.uptime.map { "\(devices) · up \($0)" } ?? devices
    case .starting: return "Starting…"
    case .needsLogin: return "Sign in required"
    case .needsApproval: return "Waiting for admin approval"
    case .lockedOut: return "Needs tailnet-lock signature"
    case .stopped: return "Off"
    case .failed: return tailnet.error ?? "Failed"
    }
  }
}

import SwiftUI
import TSMuxKit

#if os(macOS)
  import TSMuxMenuKit
#endif

@main
struct TSMuxApp: App {
  #if os(macOS)
    // The Mac gets the DMG app's menu and Settings window, run by the tunnel.
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    var body: some Scene {
      Settings { SettingsRootView(model: delegate.controller.model) }
        .commands { CloseWindowCommand() }
    }
  #else
    @State private var model = TunnelModel()

    var body: some Scene {
      WindowGroup {
        ContentView().environment(model)
      }
    }
  #endif
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
              Text("VPN")
              Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            }
          }
        } footer: {
          Text(
            "Safari and apps that use the system proxy reach every tailnet's names. Everything else goes out normally."
          )
        }

        if model.loaded && !model.tailnets.isEmpty {
          Section("Tailnets") {
            ForEach(model.tailnets) { t in
              NavigationLink(value: t.profile) { TailnetRow(tailnet: t) }
            }
            .onMove { from, to in Task { await model.move(from: from, to: to) } }
          }
        } else if !model.loaded && !model.known.isEmpty {
          // Last session's tailnets, until the tunnel says how they are now.
          Section("Tailnets") {
            ForEach(model.known) { t in
              KnownTailnetRow(name: t.name, waiting: model.isOn)
            }
          }
        } else if !model.loaded && model.isOn {
          Section {
            HStack(spacing: 12) {
              ProgressView()
              Text("Loading tailnets…").foregroundStyle(.secondary)
            }
          }
        } else {
          Section {
            Button("Set up your first tailnet…", systemImage: "plus.circle") { adding = true }
          }
        }

        Section {
          Link(destination: Project.repo) {
            Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
          }
          Link(destination: Project.issues) {
            Label("Report an issue", systemImage: "exclamationmark.bubble")
          }
          Link(destination: Project.privacy) { Label("Privacy", systemImage: "hand.raised") }
        } header: {
          Text("About")
        } footer: {
          Text("TSMux \(Project.version) · MIT licensed")
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
      if loading {
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

  /// NoState is a node still reading its saved login, not one that is off.
  private var loading: Bool { tailnet.condition == .starting || tailnet.state == "NoState" }

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
    case .stopped: return loading ? "Starting…" : "Off"
    case .failed: return tailnet.error ?? "Failed"
    }
  }
}

/// A row for a tailnet the tunnel hasn't reported on yet.
struct KnownTailnetRow: View {
  let name: String
  let waiting: Bool

  var body: some View {
    HStack(spacing: 12) {
      if waiting {
        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
      } else {
        Circle().fill(.gray).frame(width: 10, height: 10)
      }
      VStack(alignment: .leading) {
        Text(name)
        Text(waiting ? "Starting…" : "Off").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

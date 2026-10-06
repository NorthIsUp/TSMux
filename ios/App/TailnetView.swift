import SwiftUI
import TSMuxKit
import UIKit

struct TailnetView: View {
  let profile: String
  @Environment(TunnelModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var confirmRemove = false
  @State private var signIn: URL?

  var body: some View {
    if let t = model.tailnet(profile) {
      form(t).navigationTitle(t.name)
    } else {
      ContentUnavailableView("Tailnet not running", systemImage: "network.slash")
    }
  }

  private func form(_ t: ProfileStatus) -> some View {
    Form {
      if t.condition == .needsLogin {
        Section {
          if let url = t.authURL.flatMap(URL.init(string:)) {
            Button("Sign in to \(t.name)", systemImage: "person.badge.key") { signIn = url }
          } else {
            HStack(spacing: 12) {
              ProgressView()
              Text("Waiting for a sign-in link…")
            }
          }
        } footer: {
          Text("This tailnet connects on its own once you've signed in.")
        }
      }

      if let lock = t.tailnetLock, lock.lockedOut {
        lockedOut(lock)
      }

      if let health = t.healthMessages, !health.isEmpty {
        Section("Health") {
          ForEach(health, id: \.self) { h in
            Label(h, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }

      Section {
        if let u = t.user { LabeledContent("Account", value: u.loginName) }
        if let n = t.tailnet { LabeledContent("Tailnet", value: n) }
        if let m = t.machineName {
          LabeledContent("This device", value: m).textSelection(.enabled)
        }
        if let ip = t.ips?.first { LabeledContent("Address", value: ip).textSelection(.enabled) }
        if let up = t.uptime { LabeledContent("Connected for", value: up) }
        if let days = t.daysUntilExpiry {
          LabeledContent("Key expires", value: days <= 0 ? "today" : "in \(days) days")
        }
        if let e = t.error, !e.isEmpty { Text(e).foregroundStyle(.red) }
        if let c = t.suffixConflict, !c.isEmpty {
          Text("Its DNS suffix is already routed to \(c), so its names go there.")
            .foregroundStyle(.orange)
        }
      }

      if let prefs = t.prefs {
        Section("Settings") {
          toggle("Connected", prefs.connected) { $0.connected = $1 }
          toggle("Use subnet routes", prefs.acceptRoutes) { $0.acceptRoutes = $1 }
          toggle("Use tailnet DNS", prefs.acceptDNS) { $0.acceptDNS = $1 }
          toggle("Block incoming connections", prefs.shieldsUp) { $0.shieldsUp = $1 }
          exitNodePicker(t, prefs)
          if let other = t.exitNodeOverride(among: model.tailnets) {
            Text(
              "Not in use: public traffic goes through \(other)'s exit node. Only one can be active."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          if !prefs.exitNode.isEmpty {
            toggle("Allow local network access", prefs.exitNodeAllowLAN) {
              $0.exitNodeAllowLAN = $1
            }
          }
        }
      }

      if let devices = t.devices, !devices.isEmpty {
        Section {
          NavigationLink("Devices (\(devices.count))") { DevicesView(profile: profile) }
        }
      }

      Section {
        if let raw = t.adminURL, let url = URL(string: raw) {
          Link("Admin console", destination: url)
        }
        if t.isUp {
          Button("Log out") { Task { await model.logout(profile) } }
        }
        Button("Remove tailnet", role: .destructive) { confirmRemove = true }
      }
    }
    .signInSheet($signIn)
    .onChange(of: t.condition) { _, c in if c.isUp { signIn = nil } }
    .confirmationDialog(
      "Remove \(t.name)?", isPresented: $confirmRemove, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        Task {
          await model.remove(profile)
          dismiss()
        }
      }
    } message: {
      Text("This device leaves the tailnet and its sign-in is deleted.")
    }
  }

  private func lockedOut(_ lock: TailnetLock) -> some View {
    Section {
      if let k = lock.nodeKey { keyRow("Node key", k) }
      if let k = lock.publicKey { keyRow("Tailnet-lock key", k) }
      if let cmd = lock.signCommand { keyRow("Sign command", cmd) }
    } header: {
      Label("Needs tailnet-lock signature", systemImage: "lock.circle.fill")
        .foregroundStyle(.orange)
    } footer: {
      Text(
        "Signed in, but tailnet lock hides every device until an admin runs the sign "
          + "command on a device with a trusted tailnet-lock key.")
    }
  }

  private func keyRow(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      HStack {
        Text(value)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
        Spacer()
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = value }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
    }
  }

  private func toggle(
    _ title: String, _ value: Bool, _ set: @escaping (inout PrefsChange, Bool) -> Void
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { value },
        set: { v in
          var change = PrefsChange(profile: profile)
          set(&change, v)
          Task { await model.setPrefs(change) }
        }))
  }

  private func exitNodePicker(_ t: ProfileStatus, _ prefs: ProfilePrefs) -> some View {
    Picker(
      "Exit node",
      selection: Binding(
        get: { prefs.exitNode },
        set: { id in
          var change = PrefsChange(profile: profile)
          change.exitNode = id
          Task { await model.setPrefs(change) }
        })
    ) {
      Text("None").tag("")
      ForEach(t.exitNodeOptions ?? []) { n in
        Text(n.online ? n.hostname : "\(n.hostname) (offline)").tag(n.id)
      }
    }
  }
}

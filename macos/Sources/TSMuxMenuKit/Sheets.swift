import AppKit
import SwiftUI
import TSMuxKit

struct RemoveTailnetSheet: View {
  let model: AppModel
  let profile: ProfileStatus
  @Environment(\.dismiss) private var dismiss
  @State private var purge = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Remove \(profile.name)?").font(.headline)
      Text(
        "tsmux will stop running this tailnet and drop it from the configuration. "
          + "Other tailnets keep running."
      )
      .fixedSize(horizontal: false, vertical: true)
      if model.features.contains(.keepLoginOnRemove) {
        Toggle("Also delete saved credentials", isOn: $purge)
        Text(
          "Turning this on also logs the device out of the tailnet. Leave it off to keep the "
            + "saved login so re-adding does not need a new sign-in."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("This also logs the device out of the tailnet and deletes its saved login.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Remove", role: .destructive) { remove() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440, height: 260)
  }

  private func remove() {
    let key = profile.profile
    let purge = purge
    let name = profile.name
    model.selectedProfile = nil
    dismiss()
    Task {
      let outcome = await model.mutateProfiles { backend in
        await backend.removeProfile(key, purge: purge)
      }
      switch outcome {
      case .success(let r):
        if let w = r.warning { Alert.show("Removed \(name), but not logged out", w) }
      case .failure(let e):
        Alert.show("Could not remove \(name)", e.message)
      }
    }
  }
}

struct DNSSheet: View {
  let model: AppModel
  let profile: ProfileStatus
  @Environment(\.dismiss) private var dismiss
  @State private var inlineError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("DNS — \(profile.name)").font(.headline)
      statusCard
      Form {
        Toggle("Use Tailscale DNS", isOn: acceptDNS)
          .disabled(profile.prefs == nil)
        LabeledContent("Search Domain") {
          if let s = profile.magicDNSSuffix, !s.isEmpty {
            CopyableValue(value: s, monospaced: true)
          } else {
            Text("not learned yet").foregroundStyle(.secondary)
          }
        }
        Section("Extra suffixes this tailnet claims") {
          if profile.extraSuffixes.isEmpty {
            Text("none").foregroundStyle(.secondary)
          } else {
            ForEach(profile.extraSuffixes, id: \.self) { s in
              Text(s).font(.system(.body, design: .monospaced))
            }
          }
          Text(
            "Routing sends these to this tailnet. Most setups need none, and the "
              + "search domain above is learned automatically. Edit them in "
              + "config.yaml under Advanced."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)
      if let inlineError {
        Text(inlineError).font(.callout).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480, height: 420)
  }

  @ViewBuilder private var statusCard: some View {
    if let s = profile.magicDNSSuffix, !s.isEmpty {
      Label {
        Text("MagicDNS is resolving names for **\(s)** inside this tailnet only.")
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
    } else {
      Label {
        Text("Not learned yet — log in and the search domain appears here automatically.")
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
    }
  }

  private var acceptDNS: Binding<Bool> {
    Binding(
      get: { profile.prefs?.acceptDNS ?? false },
      set: { on in
        var change = PrefsChange(profile: profile.profile)
        change.acceptDNS = on
        Task { inlineError = await model.setPrefs(change) }
      })
  }
}

struct CLIIntegrationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var installedAt = Self.linked
  @State private var failure: String?

  /// No admin prompt and no root-owned directory: ~/.local/bin is the
  /// user's, and most shells' setups already put it on PATH.
  private static let link = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/tsmux")
  private static let bundled = Bundle.main.url(forResource: "tsmux", withExtension: nil)
  private static let sandboxed =
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

  private static var command: String {
    "mkdir -p ~/.local/bin && ln -sf '\(bundled?.path ?? "")' ~/.local/bin/tsmux"
  }

  private static var linked: String? {
    ([link.path, "/usr/local/bin/tsmux", "/opt/homebrew/bin/tsmux"]).first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Use tsmux from the command line").font(.headline)
      if let installedAt {
        Label("Installed at \(installedAt)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      Text(
        Self.sandboxed
          ? "Run this in Terminal to link the tsmux bundled inside TSMux:"
          : "Links the tsmux bundled inside TSMux into ~/.local/bin. It is the same as running:"
      )
      HStack(alignment: .top, spacing: 8) {
        Text(Self.command)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        CopyButton(value: Self.command)
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.red)
      }
      Spacer()
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        // A sandboxed app can't write outside its container, so the App Store
        // build hands over the command instead; the sheet is otherwise the same.
        if Self.sandboxed {
          Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.command, forType: .string)
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Install") { install() }
            .keyboardShortcut(.defaultAction)
            .disabled(Self.bundled == nil)
        }
      }
    }
    .padding(20)
    .frame(width: 460, height: 280)
  }

  private func install() {
    guard let bundled = Self.bundled else { return }
    let fm = FileManager.default
    do {
      try fm.createDirectory(
        at: Self.link.deletingLastPathComponent(), withIntermediateDirectories: true)
      if (try? fm.destinationOfSymbolicLink(atPath: Self.link.path)) != nil {
        try fm.removeItem(at: Self.link)
      }
      try fm.createSymbolicLink(at: Self.link, withDestinationURL: bundled)
      installedAt = Self.link.path
      failure = nil
    } catch {
      failure = error.localizedDescription
    }
  }
}

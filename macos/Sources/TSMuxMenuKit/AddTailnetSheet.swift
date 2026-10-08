import AppKit
import SwiftUI
import TSMuxKit

/// Sign in first, name it after, like the iOS app: the node starts under a
/// placeholder key straight away, and the name arrives prefilled from the
/// tailnet sign-in reports. `AddFlow` holds the steps both apps share.
struct AddTailnetSheet: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss

  private enum Pane {
    case signingIn, server, naming
  }

  @State private var pane: Pane = .signingIn
  @State private var key: String?
  @State private var controlURL = ""
  @State private var name = ""
  @State private var flow = AddFlow()
  @State private var step = AddFlow.Step.connecting
  @State private var elapsed = 0
  @State private var openFailed = false
  @State private var fatal: String?
  @State private var result: ProfileStatus?
  @State private var poller: Task<Void, Never>?

  /// The key the name will be saved under, skipping any other tailnet's.
  private var newKey: String {
    var k = Slug.key(name)
    while !k.isEmpty, k != key, model.configProfiles.contains(where: { $0.name == k }) {
      k = Slug.bump(k)
    }
    return k
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch pane {
      case .signingIn: signingInPane
      case .server: serverPane
      case .naming: namingPane
      }
    }
    .padding(20)
    .frame(width: 460, height: 300)
    .task { start() }
    .onDisappear { poller?.cancel() }
  }

  // MARK: signing in

  private var signingInPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a tailnet").font(.headline)
      if let fatal {
        VStack(alignment: .leading, spacing: 10) {
          Label("tsmux couldn't start.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(fatal).font(.callout).foregroundStyle(.secondary)
          Spacer()
          HStack {
            if model.features.contains(.diagnostics) {
              Button("Run Diagnostics…") { Task { await model.runDoctor() } }
            }
            Spacer()
            Button("Close") { cancelSetup(force: true) }
          }
        }
      } else {
        HStack(spacing: 10) {
          if step.isWaiting { ProgressView().controlSize(.small) }
          Text(elapsed >= 45 && step == .connecting ? Self.slowCopy : step.headline)
            .foregroundStyle(step.isWaiting ? .primary : Color.red)
          Spacer()
          Text(timeString).font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Text(
          "Your browser opens to sign in once the node is ready, about 30 seconds. "
            + "You'll name the tailnet after."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if case .needsApproval(let admin?) = step {
          Button("Open Admin Console") { NSWorkspace.shared.open(admin) }.buttonStyle(.link)
        }
        if openFailed, case .signIn(let url) = step {
          Text(url.absoluteString).font(.caption).textSelection(.enabled).lineLimit(2)
        }
        Spacer()
        HStack {
          if case .signIn(let url) = step {
            Button("Open Sign-in Page Again") { NSWorkspace.shared.open(url) }
            Button(openFailed ? "Copy Sign-in Link" : "Copy Link") { copy(url.absoluteString) }
          } else if controlURL.isEmpty && !flow.signInStarted {
            Button("Use a Self-hosted Server…") { switchToServer() }
          }
          Spacer()
          Button("Cancel") { cancelSetup(force: false) }.keyboardShortcut(.cancelAction)
        }
      }
    }
  }

  private var timeString: String {
    String(format: "%d:%02d", elapsed / 60, elapsed % 60)
  }

  private static let slowCopy =
    "This is taking longer than usual. Check that you're online — tsmux needs "
    + "to reach the coordination server."

  // MARK: self-hosted

  private var serverPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Use a self-hosted control server").font(.headline)
      TextField("https://headscale.example.com", text: $controlURL)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Control server URL")
      Text("For Headscale or another coordination server.")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Sign In") { start() }
          .keyboardShortcut(.defaultAction)
          .disabled(controlURL.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  // MARK: naming

  private var namingPane: some View {
    let suffix = result?.magicDNSSuffix ?? ""
    let proxy = result?.httpProxy ?? ""
    return VStack(alignment: .leading, spacing: 12) {
      Label("Signed in", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
        if newKey.isEmpty {
          Text("Enter a name using letters or numbers.")
            .font(.caption).foregroundStyle(.secondary)
        } else if let tailnet = result?.tailnet, !tailnet.isEmpty {
          Text("\(tailnet) · profile: \(newKey)").font(.caption).foregroundStyle(.secondary)
        }
      }
      if suffix.isEmpty {
        Text(
          "We couldn't detect this tailnet's DNS suffix automatically, so hostnames "
            + "won't route yet. You can add one in Settings, or use this tailnet's "
            + "proxy directly at \(proxy)."
        )
        .fixedSize(horizontal: false, vertical: true)
      } else {
        // Interpolated rather than concatenated: Text's `+` is deprecated as of
        // macOS 26, and inline styling carries through interpolation.
        Text(
          "Anything ending in \(Text(".\(suffix)").font(.system(.body, design: .monospaced))) now goes to this tailnet."
        )
      }
      Spacer()
      HStack {
        if suffix.isEmpty {
          Button("Copy Proxy Address") { copy(proxy) }
        } else if model.features.contains(.pacToggle) {
          if !model.pacApplied {
            Button("Route System Traffic") { model.togglePAC() }
          }
          Button("Copy PAC URL") { Task { copy(await model.backend.pacURL() ?? "") } }
        }
        Spacer()
        Button("Done") { finish() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(newKey.isEmpty)
      }
    }
  }

  // MARK: actions

  private func start() {
    let k = AddFlow.placeholderKey { k in model.configProfiles.contains { $0.name == k } }
    let url = controlURL.trimmingCharacters(in: .whitespaces)
    // D13: bare hostnames go to the only tailnet there is, and no further.
    let matchRoot = model.configProfiles.isEmpty

    key = k
    pane = .signingIn
    fatal = nil
    elapsed = 0
    Task {
      let outcome = await model.mutateProfiles { backend in
        await backend.addProfile(
          k, displayName: AddFlow.placeholderName, controlURL: url.isEmpty ? nil : url,
          matchRoot: matchRoot)
      }
      if case .failure(let e) = outcome {
        fatal = e.message
        return
      }
      poll(k)
    }
  }

  private func poll(_ key: String) {
    poller?.cancel()
    poller = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        elapsed += 1
        model.refresh()
        let p = model.profiles.first { $0.profile == key }
        step = AddFlow.step(p)
        if let url = flow.autoOpen(step) { openFailed = !NSWorkspace.shared.open(url) }
        if case .signedIn(let suggested) = step {
          name = suggested
          result = p
          pane = .naming
          return
        }
      }
    }
  }

  private func switchToServer() {
    poller?.cancel()
    pane = .server
    if let key { remove(key) }
    key = nil
  }

  /// Renaming restarts the daemon, which takes seconds; the sheet shouldn't wait.
  private func finish() {
    guard let key else { return }
    let newKey = newKey
    let display = name.trimmingCharacters(in: .whitespaces)
    dismiss()
    Task {
      let outcome = await model.mutateProfiles { backend in
        await backend.renameProfile(key, to: newKey, displayName: display)
      }
      if case .failure(let e) = outcome { Alert.show("Couldn't rename the tailnet", e.message) }
    }
  }

  private func cancelSetup(force: Bool) {
    poller?.cancel()
    if flow.signInStarted && !force {
      let a = NSAlert()
      a.messageText = "Stop adding this tailnet?"
      a.informativeText =
        "If you already signed in, this tailnet will be removed and you'll need "
        + "to sign in again next time."
      a.addButton(withTitle: "Keep Going")
      a.addButton(withTitle: "Remove")
      guard a.runModal() == .alertSecondButtonReturn else {
        if let key { poll(key) }
        return
      }
    }
    dismiss()
    if let key { remove(key) }
  }

  /// Removal restarts the daemon too, so it runs after the sheet is gone.
  private func remove(_ key: String) {
    Task {
      await model.mutateProfiles { backend in await backend.removeProfile(key, purge: true) }
    }
  }

  private func copy(_ s: String) {
    guard !s.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
  }
}

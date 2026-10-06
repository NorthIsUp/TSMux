import SwiftUI
import TSMuxKit

/// Sign in first, name it after: the tailnet's name is only known once its
/// node has logged in, so the name field arrives prefilled with it.
struct AddTailnetView: View {
  /// Called with the new tailnet's key once it's named, so the caller can
  /// open its page.
  var onAdded: (String) -> Void
  @Environment(TunnelModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var controlURL = ""
  @State private var customServer = false
  @State private var key: String?
  @State private var signedIn = false
  @State private var name = ""
  @State private var busy = false
  @State private var failure: String?
  @State private var signIn: URL?
  @State private var openedAuthURL: String?
  @State private var confirmCancel = false

  var body: some View {
    NavigationStack {
      Group {
        if signedIn, let key {
          naming(key)
        } else if let key {
          signingIn(key)
        } else if customServer {
          serverForm
        } else {
          Form { starting }
        }
      }
      .navigationTitle("Add a tailnet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if key == nil { dismiss() } else { confirmCancel = true }
          }
        }
        if signedIn || customServer && key == nil {
          ToolbarItem(placement: .confirmationAction) {
            if busy {
              ProgressView()
            } else if signedIn {
              Button("Done") { Task { await finish() } }.disabled(Slug.key(name).isEmpty)
            } else {
              Button("Sign In") { Task { await begin() } }
                .disabled(controlURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
          }
        }
      }
      .interactiveDismissDisabled(busy || key != nil)
      .confirmationDialog(
        "Stop adding this tailnet?", isPresented: $confirmCancel, titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
          Task {
            if let key { await model.remove(key) }
            dismiss()
          }
        }
        Button("Keep Going", role: .cancel) {}
      } message: {
        Text("If you already signed in, you'll need to sign in again next time.")
      }
      .signInSheet($signIn)
    }
    .task { if !customServer { await begin() } }
  }

  /// Shown only while the first node starts, before there's a link to open.
  @ViewBuilder private var starting: some View {
    Section {
      if busy || failure == nil {
        HStack(spacing: 12) {
          ProgressView()
          Text("Starting sign-in…")
        }
      } else {
        Button("Try Again", systemImage: "arrow.clockwise") { Task { await begin() } }
      }
    } footer: {
      if let failure { Text(failure).foregroundStyle(.red) }
    }
  }

  private var serverForm: some View {
    Form {
      Section {
        TextField("https://headscale.example.com", text: $controlURL)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          .autocorrectionDisabled()
      } header: {
        Text("Control server")
      } footer: {
        if let failure { Text(failure).foregroundStyle(.red) }
      }
    }
  }

  private func signingIn(_ key: String) -> some View {
    let t = model.tailnet(key)
    let auth = t?.authURL.flatMap(URL.init(string:))
    return Form {
      Section {
        HStack(spacing: 12) {
          ProgressView()
          Text(headline(t, hasLink: auth != nil))
        }
        if let auth {
          Button("Open Sign-in Page", systemImage: "person.badge.key") { signIn = auth }
        }
      } footer: {
        if let e = t?.error, !e.isEmpty {
          Text(e).foregroundStyle(.red)
        } else if let state = t?.state, !state.isEmpty {
          Text("State: \(state)")
        }
      }
      if t?.condition == .needsApproval, let admin = t?.adminURL.flatMap(URL.init(string:)) {
        Section {
          Link("Open Admin Console", destination: admin)
        } footer: {
          Text("If you're the admin, approve this device under Machines.")
        }
      }
      if controlURL.isEmpty {
        Section {
          Button("Use a Self-hosted Server…") { Task { await switchToCustomServer(key) } }
        }
      }
    }
    .task(id: key) { await watch(key) }
  }

  private func headline(_ t: ProfileStatus?, hasLink: Bool) -> String {
    if t?.condition == .needsApproval {
      return "Signed in. Waiting for a tailnet admin to approve this device…"
    }
    if hasLink { return "Sign in to add your tailnet." }
    return t?.condition == .needsLogin
      ? "Waiting for a sign-in link…" : "Connecting to the coordination server…"
  }

  private func naming(_ key: String) -> some View {
    let t = model.tailnet(key)
    return Form {
      Section {
        TextField("Name", text: $name).textInputAutocapitalization(.words)
      } header: {
        Text("Name")
      } footer: {
        if let failure {
          Text(failure).foregroundStyle(.red)
        } else if let tailnet = t?.tailnet, !tailnet.isEmpty {
          Text("Signed in to \(tailnet)" + (t?.user.map { " as \($0.loginName)" } ?? "") + ".")
        }
      }
    }
  }

  private func begin() async {
    busy = true
    defer { busy = false }
    failure = nil
    do {
      key = try await model.add(controlURL: controlURL.trimmingCharacters(in: .whitespaces))
    } catch {
      failure = error.localizedDescription
    }
  }

  private func switchToCustomServer(_ key: String) async {
    signIn = nil
    self.key = nil
    customServer = true
    await model.remove(key)
  }

  private func finish() async {
    guard let key else { return }
    busy = true
    defer { busy = false }
    do {
      let final = try await model.rename(key, to: name.trimmingCharacters(in: .whitespaces))
      dismiss()
      onAdded(final)
    } catch {
      failure = error.localizedDescription
    }
  }

  /// Opens each new sign-in link once, and moves on to naming when the
  /// tailnet is up.
  private func watch(_ key: String) async {
    while !Task.isCancelled {
      await model.refresh()
      if let t = model.tailnet(key) {
        if t.condition == .running {
          signIn = nil
          name = Slug.suggestedName(tailnet: t.tailnet, magicDNSSuffix: t.magicDNSSuffix)
          signedIn = true
          return
        }
        // Latch on the URL: the same link must not reopen, but a different
        // one is a genuine re-registration.
        if let raw = t.authURL, !raw.isEmpty, raw != openedAuthURL, let url = URL(string: raw) {
          openedAuthURL = raw
          signIn = url
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }
}

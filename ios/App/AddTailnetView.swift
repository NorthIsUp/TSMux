import SwiftUI
import TSMuxKit

/// The name is the only thing you type: the DNS suffix is learned at sign-in.
/// Adding goes straight on to signing in, and the sheet closes once the
/// tailnet is connected, like the macOS add sheet.
struct AddTailnetView: View {
  /// Called with the new tailnet's key once it's connected, so the caller can
  /// open its page.
  var onAdded: (String) -> Void
  @Environment(TunnelModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var controlURL = ""
  @State private var key: String?
  @State private var busy = false
  @State private var failure: String?
  @State private var signIn: URL?
  @State private var openedAuthURL: String?
  @State private var confirmCancel = false

  var body: some View {
    NavigationStack {
      Group {
        if let key { setup(key) } else { form }
      }
      .navigationTitle("Add a tailnet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if key == nil { dismiss() } else { confirmCancel = true }
          }
        }
        if key == nil {
          ToolbarItem(placement: .confirmationAction) {
            if busy {
              ProgressView()
            } else {
              Button("Add") { Task { await add() } }.disabled(Slug.key(name).isEmpty)
            }
          }
        }
      }
      .interactiveDismissDisabled(busy || key != nil)
      .confirmationDialog(
        "Stop setting up \(name)?", isPresented: $confirmCancel, titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
          Task {
            if let key { await model.remove(key) }
            dismiss()
          }
        }
        Button("Keep Setting Up", role: .cancel) {}
      } message: {
        Text("If you already signed in, you'll need to sign in again next time.")
      }
      .signInSheet($signIn)
    }
  }

  private var form: some View {
    Form {
      Section {
        TextField("Work", text: $name).textInputAutocapitalization(.words)
      } header: {
        Text("Name")
      } footer: {
        if let failure { Text(failure).foregroundStyle(.red) }
      }
      Section {
        TextField("https://headscale.example.com", text: $controlURL)
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
          .autocorrectionDisabled()
      } header: {
        Text("Self-hosted control server")
      } footer: {
        Text("Leave empty for Tailscale.")
      }
    }
  }

  private func setup(_ key: String) -> some View {
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
        if let e = t?.error, !e.isEmpty { Text(e).foregroundStyle(.red) }
      }
    }
    .task(id: key) { await watch(key) }
  }

  private func headline(_ t: ProfileStatus?, hasLink: Bool) -> String {
    if hasLink { return "Sign in to finish adding \(name)." }
    return t?.condition == .needsLogin
      ? "Waiting for a sign-in link…" : "Connecting to the coordination server…"
  }

  private func add() async {
    busy = true
    defer { busy = false }
    do {
      key = try await model.add(
        displayName: name.trimmingCharacters(in: .whitespaces),
        controlURL: controlURL.trimmingCharacters(in: .whitespaces))
    } catch {
      failure = error.localizedDescription
    }
  }

  /// Opens each new sign-in link once, and finishes when the tailnet is up.
  private func watch(_ key: String) async {
    while !Task.isCancelled {
      await model.refresh()
      if let t = model.tailnet(key) {
        if t.condition == .running {
          signIn = nil
          dismiss()
          onAdded(key)
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

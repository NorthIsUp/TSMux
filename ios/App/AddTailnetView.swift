import SwiftUI
import TSMuxKit

/// The name is the only thing you type: the DNS suffix is learned at sign-in.
/// Once added, the tailnet's own page carries the sign-in link.
struct AddTailnetView: View {
  /// Called with the new tailnet's key, so the caller can open its page.
  var onAdded: (String) -> Void
  @Environment(TunnelModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var controlURL = ""
  @State private var busy = false
  @State private var failure: String?

  var body: some View {
    NavigationStack {
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
      .navigationTitle("Add a tailnet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          if busy {
            ProgressView()
          } else {
            Button("Add") { Task { await add() } }.disabled(Slug.key(name).isEmpty)
          }
        }
      }
      .interactiveDismissDisabled(busy)
    }
  }

  private func add() async {
    busy = true
    defer { busy = false }
    do {
      let key = try await model.add(
        displayName: name.trimmingCharacters(in: .whitespaces),
        controlURL: controlURL.trimmingCharacters(in: .whitespaces))
      dismiss()
      onAdded(key)
    } catch {
      failure = error.localizedDescription
    }
  }
}

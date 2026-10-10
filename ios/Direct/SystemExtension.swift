import AppKit
import SystemExtensions

/// A Developer ID build carries its tunnel as a system extension, which macOS
/// installs only when asked and runs only once the user approves it in System
/// Settings. The App Store build's app extension needs neither step.
@MainActor
final class SystemExtension: NSObject {
  static let shared = SystemExtension()

  private var waiting: [CheckedContinuation<Void, any Error>] = []
  private var activated = false

  /// Returns once the extension is installed, which for a first install means
  /// after the user approves it. Every launch asks again, so an update replaces
  /// the running copy.
  func activate() async throws {
    if activated { return }
    try await withCheckedThrowingContinuation { c in
      waiting.append(c)
      guard waiting.count == 1 else { return }
      let request = OSSystemExtensionRequest.activationRequest(
        forExtensionWithIdentifier: (Bundle.main.bundleIdentifier ?? "") + ".tunnel",
        queue: .main)
      request.delegate = self
      OSSystemExtensionManager.shared.submitRequest(request)
    }
  }

  private func finish(_ result: Result<Void, any Error>) {
    if case .success = result { activated = true }
    let resume = waiting
    waiting = []
    for c in resume { c.resume(with: result) }
  }

  private func askForApproval() {
    let a = NSAlert()
    a.messageText = "Allow the TSMux network extension"
    a.informativeText =
      "macOS needs your approval before TSMux can connect. Turn on TSMux under "
      + "Network Extensions in System Settings, then come back here."
    a.addButton(withTitle: "Open System Settings")
    a.addButton(withTitle: "Later")
    NSApp.activate()
    if a.runModal() == .alertFirstButtonReturn,
      let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    {
      NSWorkspace.shared.open(url)
    }
  }
}

// The request runs on the main queue (see `activate`), so every callback below
// is already on the main actor.
extension SystemExtension: OSSystemExtensionRequestDelegate {
  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    MainActor.assumeIsolated { askForApproval() }
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    didFinishWithResult result: OSSystemExtensionRequest.Result
  ) {
    MainActor.assumeIsolated { finish(.success(())) }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
    MainActor.assumeIsolated { finish(.failure(error)) }
  }
}

import SwiftTerm
import SwiftUI

/// An SSH shell: the terminal, plus what the connection needs from the user
/// along the way — a check-mode sign-in, trusting an unknown host key, or
/// reconnecting after the session drops.
public struct ShellView: View {
  @State private var connection: SSHConnection
  @State private var terminal = TerminalBox()
  @State private var confirmTrust = false
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  private let tailnet: String

  /// `tailnet` scopes keys the user trusts, so one host name in two tailnets
  /// never shares a key.
  public init(request: SSHRequest, tailnet: String) {
    var request = request
    if request.hostKeys.isEmpty {
      request.trustedKey = TrustedHostKeys.key(tailnet: tailnet, host: request.host)
    }
    _connection = State(initialValue: SSHConnection(request))
    self.tailnet = tailnet
  }

  public var body: some View {
    TerminalSurface(connection: connection, box: terminal)
      .overlay(alignment: .bottom) { banner }
      .onAppear { connect() }
      .onDisappear { connection.close() }
      // iOS drops the socket while the app is suspended; come back connected.
      .onChange(of: scenePhase) { _, phase in
        if phase == .active, connection.state.phase == .closed { connect() }
      }
      .onChange(of: connection.state.isUnknownHostKey) { _, unknown in
        if unknown { confirmTrust = true }
      }
      .confirmationDialog(
        "Trust this host?", isPresented: $confirmTrust, titleVisibility: .visible
      ) {
        Button("Trust and Connect") {
          guard let key = connection.state.hostKey else { return }
          TrustedHostKeys.trust(key, tailnet: tailnet, host: connection.request.host)
          connection.trust(key, output: feed)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "\(connection.request.host) doesn't advertise a host key through the tailnet. "
            + "Its key fingerprint is \(connection.state.fingerprint ?? "unknown")."
        )
      }
  }

  @ViewBuilder private var banner: some View {
    let state = connection.state
    switch state.phase {
    case .connecting:
      HStack(spacing: 10) {
        ProgressView()
        Text(state.urls?.isEmpty == false ? "Waiting for you to sign in…" : "Connecting…")
        if let url = state.urls?.last.flatMap(URL.init(string:)) {
          Button("Sign In") { openURL(url) }.buttonStyle(.borderedProminent)
        }
      }
      .padding(12)
      .background(.regularMaterial, in: .capsule)
      .padding()
    case .failed where state.isUnknownHostKey:
      EmptyView()
    case .failed, .closed:
      VStack(spacing: 8) {
        Text(message(state)).font(.callout).multilineTextAlignment(.center)
        if !state.isHostKeyMismatch {
          Button("Reconnect") { connect() }.buttonStyle(.borderedProminent)
        }
      }
      .padding(14)
      .background(.regularMaterial, in: .rect(cornerRadius: 14))
      .padding()
    case .open:
      EmptyView()
    }
  }

  private func message(_ s: SSHState) -> String {
    if s.isHostKeyMismatch {
      return "\(connection.request.host)'s host key changed (\(s.fingerprint ?? "unknown")). "
        + "Not connecting: the host was reinstalled, or something is impersonating it."
    }
    if s.phase == .closed { return "Disconnected." }
    return s.error ?? "Couldn't connect."
  }

  private func connect() { connection.start(output: feed) }

  private func feed(_ bytes: [UInt8]) { terminal.view?.feed(byteArray: bytes[...]) }
}

/// Holds the platform terminal view so the connection's output can reach it.
@MainActor
final class TerminalBox {
  weak var view: TerminalView?
}

/// Bridges SwiftTerm's delegate to the connection.
@MainActor
final class TerminalCoordinator: NSObject {
  let connection: SSHConnection

  init(connection: SSHConnection) { self.connection = connection }
}

// SwiftTerm's delegate protocol predates strict concurrency, but it only ever
// calls these from the view, on the main thread.
extension TerminalCoordinator: @preconcurrency TerminalViewDelegate {
  func send(source: TerminalView, data: ArraySlice<UInt8>) { connection.send(Array(data)) }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    connection.resize(cols: newCols, rows: newRows)
  }

  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

  /// OSC 52 from the remote side (tmux, vim). Writing the clipboard only;
  /// this delegate gives the remote no way to read it.
  func clipboardCopy(source: TerminalView, content: Data) {
    guard let text = String(data: content, encoding: .utf8) else { return }
    #if os(iOS)
      UIPasteboard.general.string = text
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #endif
  }

  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") else { return }
    #if os(iOS)
      UIApplication.shared.open(url)
    #else
      NSWorkspace.shared.open(url)
    #endif
  }
}

#if os(iOS)
  struct TerminalSurface: UIViewRepresentable {
    let connection: SSHConnection
    let box: TerminalBox

    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(connection: connection) }

    func makeUIView(context: Context) -> TerminalView {
      let view = TerminalView(frame: .zero)
      view.terminalDelegate = context.coordinator
      box.view = view
      DispatchQueue.main.async { _ = view.becomeFirstResponder() }
      return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}
  }
#else
  struct TerminalSurface: NSViewRepresentable {
    let connection: SSHConnection
    let box: TerminalBox

    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(connection: connection) }

    func makeNSView(context: Context) -> TerminalView {
      let view = TerminalView(frame: .zero)
      view.terminalDelegate = context.coordinator
      box.view = view
      DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
      return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}
  }
#endif

import SwiftTerm
import SwiftUI

/// An SSH shell to a Tailscale SSH machine: the terminal, plus what the
/// connection needs along the way — a check-mode sign-in, or reconnecting
/// after the session drops.
public struct ShellView: View {
  @State private var connection: SSHConnection
  @State private var terminal = TerminalBox()
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  private let target: ShellTarget

  public init(target: ShellTarget) {
    self.target = target
    _connection = State(initialValue: SSHConnection(target.request))
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
      // The device list stops offering a shell here for a while.
      .onChange(of: connection.state.isDenied) { _, denied in
        if denied { SSHAccess.markDenied(target) }
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
    case .failed, .closed:
      VStack(spacing: 8) {
        Text(message(state)).font(.callout).multilineTextAlignment(.center)
        if !state.isHostKeyMismatch && !state.isDenied {
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
      return "\(target.host)'s host key changed (\(s.fingerprint ?? "unknown")). "
        + "Not connecting: the host was reinstalled, or something is impersonating it."
    }
    if s.isDenied {
      return "Tailscale SSH doesn't let \(target.user) into this machine."
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

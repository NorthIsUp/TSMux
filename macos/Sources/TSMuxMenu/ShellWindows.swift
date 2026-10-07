import AppKit
import SwiftUI
import TSMuxShell

/// One window per shell. A menu bar app has no window list of its own, so
/// this keeps them alive until they close.
@MainActor
enum ShellWindows {
  private static var open: [NSWindow] = []

  static func open(_ target: ShellTarget) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = target.device.split(separator: ".").first.map(String.init) ?? target.device
    window.contentViewController = NSHostingController(rootView: ShellView(target: target))
    window.isReleasedWhenClosed = false
    window.center()
    var token: (any NSObjectProtocol)?
    token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak window] _ in
      MainActor.assumeIsolated {
        open.removeAll { $0 === window }
        if let token { NotificationCenter.default.removeObserver(token) }
      }
    }
    open.append(window)
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }
}

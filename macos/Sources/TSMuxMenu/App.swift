import AppKit
import SwiftUI
import TSMuxKit
import TSMuxMenuKit

@main
struct TSMuxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Settings { SettingsRootView(model: delegate.controller.model) }
      .commands { CloseWindowCommand() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = Controller(backend: DaemonBackend(), updater: SparkleUpdater())
  private var signalSources: [DispatchSourceSignal] = []

  func applicationWillFinishLaunching(_ notification: Notification) {
    assert(Slug.selfCheck(), "profile-key derivation is wrong")
    // Not an `assert`: the app ships `-c release`, where asserts are compiled
    // out, so the check would only ever run in a build nobody launches. A
    // missing symbol is a blank row, not a reason to refuse to start, so it
    // logs rather than traps.
    _ = Controller.iconSelfCheck()
    // Covers running the binary outside the .app bundle, where LSUIElement is absent.
    NSApp.setActivationPolicy(.accessory)
  }

  // Documented ordering: the status item is created after launch finishes.
  func applicationDidFinishLaunching(_ notification: Notification) {
    let userLaunched =
      notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true
    installSignalHandlers()
    Task {
      await controller.install()
      maybeShowFirstRun(userLaunched: userLaunched)
    }
  }

  /// An app that throws a window in your face at every login is malware
  /// behaviour; a silent menu-bar icon after a double-click tells the user
  /// nothing. Show it once, and only when the user launched us themselves.
  private func maybeShowFirstRun(userLaunched: Bool) {
    guard controller.model.configState == .firstRun else { return }
    guard userLaunched,
      !UserDefaults.standard.bool(forKey: AppModel.didShowFirstRunKey)
    else { return }
    UserDefaults.standard.set(true, forKey: AppModel.didShowFirstRunKey)
    SettingsScene.open()
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller.shutdown()
  }

  /// AppKit only runs applicationWillTerminate for an orderly quit, so a plain
  /// SIGTERM (pkill, a rebuild script, logout) would leave the daemon running
  /// with the tailnets up and the ports held. Catch the signals ourselves and
  /// route them through the same shutdown.
  func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)  // the dispatch source is the handler now
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      src.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
      src.resume()
      signalSources.append(src)
    }
  }
}

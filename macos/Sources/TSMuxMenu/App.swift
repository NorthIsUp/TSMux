import AppKit
import SwiftUI

@main
struct TSMuxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Settings { SettingsRootView(model: delegate.controller.model) }
      .commands {
        // An .accessory app gets no File menu, and ⌘W is the only editing
        // shortcut SwiftUI does not supply on its own.
        CommandGroup(after: .appSettings) {
          Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w")
        }
      }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = Controller()
  private var signalSources: [DispatchSourceSignal] = []

  func applicationWillFinishLaunching(_ notification: Notification) {
    assert(Slug.selfCheck(), "profile-key derivation is wrong")
    assert(Controller.iconSelfCheck(), "a status symbol does not resolve")
    // Covers running the binary outside the .app bundle, where LSUIElement is absent.
    NSApp.setActivationPolicy(.accessory)
  }

  // Documented ordering: the status item is created after launch finishes.
  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.install()
    installSignalHandlers()
    maybeShowFirstRun(notification)
  }

  /// An app that throws a window in your face at every login is malware
  /// behaviour; a silent menu-bar icon after a double-click tells the user
  /// nothing. Show it once, and only when the user launched us themselves.
  private func maybeShowFirstRun(_ notification: Notification) {
    guard controller.model.configState == .firstRun else { return }
    let userLaunched =
      notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true
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

enum SettingsScene {
  /// The Settings scene owns its window, `openSettings` exists only inside a
  /// view, and `showSettingsWindow:` answers `sendAction` and then opens
  /// nothing on macOS 26 — measured. Performing the app menu's own ⌘, item is
  /// what actually opens it.
  @MainActor static func open() {
    NSApp.activate()
    guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu,
      let i = appMenu.items.firstIndex(where: {
        $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
      })
    else {
      NSLog("tsmux: no Settings item in the app menu")
      return
    }
    appMenu.performActionForItem(at: i)
  }
}

struct SettingsRootView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView(selection: $model.selectedTab) {
      AccountsTab(model: model)
        .tabItem { Label("Accounts", systemImage: "person.2") }
        .tag(SettingsTab.accounts)
      GlobalSettingsTab(model: model)
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(SettingsTab.settings)
      AboutTab()
        .tabItem { Label("About", systemImage: "info.circle") }
        .tag(SettingsTab.about)
    }
    .frame(minWidth: 680, minHeight: 480)
  }
}

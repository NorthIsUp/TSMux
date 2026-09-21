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

/// One sidebar, not a tab bar. `NavigationSplitView` owns the window root,
/// which is what makes the window non-opaque and gives Liquid Glass something
/// to refract — the tab bar was forcing the sidebar to be contained, and a
/// contained sidebar gets no material, no vibrancy and none of the system's
/// selected-row handling. Settings and About are sidebar rows now.
struct SettingsRootView: View {
  @Bindable var model: AppModel

  @State private var showRemove = false
  @State private var showDNS = false

  var body: some View {
    NavigationSplitView {
      List(selection: routeBinding) {
        if !model.displayProfiles.isEmpty {
          Section {
            ForEach(model.displayProfiles) { p in
              TailnetRow(profile: p, showProxy: model.displayProfiles.count > 1)
                .tag(Route.tailnet(p.profile))
            }
          } header: {
            // Add belongs to the list. Remove belongs to the tailnet, where
            // "Remove Tailnet…" sits in its own settings and names what it will
            // delete; a minus here would act on whatever happened to be
            // selected.
            HStack {
              Text("Tailnets")
              Spacer()
              Button {
                model.pendingAdd = true
              } label: {
                Image(systemName: "plus")
              }
              .buttonStyle(.borderless)
              .imageScale(.large)
              .help("Add a tailnet")
              .accessibilityLabel("Add a tailnet")
            }
          }
        }
        Section("App") {
          Label("Settings", systemImage: "gearshape").tag(Route.settings)
          Label("About", systemImage: "info.circle").tag(Route.about)
        }
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
      // The sidebar is the navigation — collapsing it strands you with no way
      // to reach Settings, About or another tailnet. On the column's content
      // rather than the split view, where the modifier does nothing.
      .toolbar(removing: .sidebarToggle)
    } detail: {
      detail
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
    .frame(minWidth: 680, minHeight: 480)
    .sheet(isPresented: $model.pendingAdd) { AddTailnetSheet(model: model) }
    .sheet(isPresented: $showRemove) {
      if let p = model.selection { RemoveTailnetSheet(model: model, profile: p) }
    }
    .sheet(isPresented: $showDNS) {
      if let p = model.selection { DNSSheet(model: model, profile: p) }
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selectedTab {
    case .settings:
      GlobalSettingsTab(model: model).navigationTitle("Settings")
    case .about:
      AboutTab().navigationTitle("About")
    case .accounts:
      if model.displayProfiles.isEmpty {
        NoTailnets(model: model)
      } else if let p = model.selection {
        AccountDetail(model: model, profile: p, showRemove: $showRemove, showDNS: $showDNS)
          .navigationTitle(p.name)
          .navigationSubtitle(p.condition.label)
      } else {
        Text("Select a tailnet").foregroundStyle(.secondary)
      }
    }
  }

  /// The sidebar has one selection, the model has two fields — which tab and
  /// which tailnet — and the menu bar writes both directly. Mapping here keeps
  /// those call sites working rather than migrating them to a route.
  private var routeBinding: Binding<Route?> {
    Binding(
      get: {
        switch model.selectedTab {
        case .accounts: model.selection.map { Route.tailnet($0.profile) }
        case .settings: .settings
        case .about: .about
        }
      },
      set: { route in
        switch route {
        case .tailnet(let profile):
          model.selectedTab = .accounts
          model.selectedProfile = profile
        case .settings: model.selectedTab = .settings
        case .about: model.selectedTab = .about
        case nil: break
        }
      })
  }
}

enum Route: Hashable {
  case tailnet(String)
  case settings
  case about
}

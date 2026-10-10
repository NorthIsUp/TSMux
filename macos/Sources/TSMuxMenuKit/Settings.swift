import AppKit
import SwiftUI
import TSMuxKit

public enum SettingsScene {
  /// The Settings scene owns its window, `openSettings` exists only inside a
  /// view, and `showSettingsWindow:` answers `sendAction` and then opens
  /// nothing on macOS 26 — measured. Performing the app menu's own ⌘, item is
  /// what actually opens it.
  @MainActor public static func open() {
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

  /// Brings Settings back in front of whatever took focus: the browser after
  /// sign-in, or the system's VPN prompt. An accessory app isn't reactivated
  /// when those go away.
  @MainActor public static func raise() {
    NSApp.activate()
    NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
  }
}

/// One sidebar, not a tab bar. `NavigationSplitView` owns the window root,
/// which is what makes the window non-opaque and gives Liquid Glass something
/// to refract — the tab bar was forcing the sidebar to be contained, and a
/// contained sidebar gets no material, no vibrancy and none of the system's
/// selected-row handling. Settings and About are sidebar rows now.
public struct SettingsRootView: View {
  @Bindable var model: AppModel

  public init(model: AppModel) { self.model = model }

  @State private var showRemove = false
  @State private var showDNS = false

  public var body: some View {
    NavigationSplitView {
      List(selection: routeBinding) {
        if !model.displayProfiles.isEmpty {
          Section {
            ForEach(model.displayProfiles) { p in
              TailnetRow(profile: p, showProxy: model.displayProfiles.count > 1)
                .tag(Route.tailnet(p.profile))
            }
            .onMove { model.moveProfile(from: $0, to: $1) }
          } header: {
            // Add belongs to the list; remove belongs to the tailnet, where
            // "Remove Tailnet…" names what it will delete rather than acting on
            // whatever happens to be selected.
            HStack {
              Text("Tailnets").font(Self.sectionHeader)
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
        Section {
          Label("Settings", systemImage: "gearshape").tag(Route.settings)
          Label("About", systemImage: "info.circle").tag(Route.about)
        } header: {
          Text("App").font(Self.sectionHeader)
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
      AboutTab(model: model).navigationTitle("About")
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

extension SettingsRootView {
  /// A step up from the system's sidebar header, which is small enough that
  /// the sections read as faint labels rather than as headings.
  static let sectionHeader = Font.callout.weight(.semibold)
}

enum Route: Hashable {
  case tailnet(String)
  case settings
  case about
}

/// An .accessory app gets no File menu, and ⌘W is the only editing shortcut
/// SwiftUI does not supply on its own.
public struct CloseWindowCommand: Commands {
  public init() {}

  public var body: some Commands {
    CommandGroup(after: .appSettings) {
      Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
        .keyboardShortcut("w")
    }
  }
}

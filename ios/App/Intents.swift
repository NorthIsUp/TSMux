import AppIntents

/// Connect and disconnect from Spotlight, Siri, Shortcuts and the Action
/// button without opening the app. Both use the app's own start and stop, so
/// on-demand is set and cleared the same way the switch does it.
struct ConnectIntent: AppIntent {
  static let title: LocalizedStringResource = "Connect TSMux"
  static let description = IntentDescription(
    "Turns on the TSMux VPN so every tailnet is reachable.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await TunnelModel().start()
    return .result(dialog: "TSMux is connected.")
  }
}

struct DisconnectIntent: AppIntent {
  static let title: LocalizedStringResource = "Disconnect TSMux"
  static let description = IntentDescription("Turns off the TSMux VPN.")

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await TunnelModel().stop()
    return .result(dialog: "TSMux is disconnected.")
  }
}

struct TSMuxShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ConnectIntent(),
      phrases: ["Connect \(.applicationName)", "Turn on \(.applicationName)"],
      shortTitle: "Connect",
      systemImageName: "network")
    AppShortcut(
      intent: DisconnectIntent(),
      phrases: ["Disconnect \(.applicationName)", "Turn off \(.applicationName)"],
      shortTitle: "Disconnect",
      systemImageName: "network.slash")
  }
}

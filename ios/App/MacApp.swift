#if os(macOS)
  import AppKit
  import NetworkExtension
  import TSMuxKit
  import TSMuxMenuKit

  @MainActor
  final class MacAppDelegate: NSObject, NSApplicationDelegate {
    #if DIRECT
      let controller = Controller(backend: TunnelBackend(), updater: SparkleUpdater())
    #else
      let controller = Controller(backend: TunnelBackend(), updater: nil)
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
      _ = Controller.iconSelfCheck()
      NSApp.setActivationPolicy(.accessory)
      #if DIRECT
        DaemonMigration.run()
        Task { try? await SystemExtension.shared.activate() }
      #endif
    }

    /// Settings opens once, on the first launch the user made themselves, as
    /// the DMG app does.
    func applicationDidFinishLaunching(_ notification: Notification) {
      let userLaunched =
        notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true
      Task {
        await controller.install()
        guard controller.model.configState == .firstRun, userLaunched,
          !UserDefaults.standard.bool(forKey: AppModel.didShowFirstRunKey)
        else { return }
        UserDefaults.standard.set(true, forKey: AppModel.didShowFirstRunKey)
        SettingsScene.open()
      }
    }
  }

  /// Runs the tailnets in this app's packet tunnel, the same Go core the iOS
  /// app uses. The VPN is the service: turning it off stops every tailnet, and
  /// quitting the app leaves it running, as a system VPN does.
  @MainActor
  final class TunnelBackend: Backend {
    let features: BackendFeatures = [.systemVPN, .cliIntegration]
    var onChange: (() -> Void)?

    private let tunnel = TunnelModel()
    private var observer: (any NSObjectProtocol)?

    init() {
      Task {
        await tunnel.load()
        observer = NotificationCenter.default.addObserver(
          forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.onChange?() }
        }
        onChange?()
      }
    }

    var isAvailable: Bool { true }
    var isStarting: Bool { [.connecting, .reasserting].contains(tunnel.vpnStatus) }
    var crashLine: String? { nil }
    var ownsService: Bool { true }
    var configFile: URL? { nil }

    func start() {
      Task {
        do {
          try await startTunnel()
        } catch {
          Alert.show("Could not turn on TSMux", error.localizedDescription)
        }
        onChange?()
      }
    }

    /// A Developer ID build's tunnel is a system extension that has to be
    /// installed, and approved the first time, before it can start. The
    /// first start also shows the system's "Add VPN Configurations" prompt,
    /// which takes focus and leaves Settings behind whatever was in front.
    private func startTunnel() async throws {
      #if DIRECT
        try await SystemExtension.shared.activate()
      #endif
      let prompts = tunnel.vpnStatus == .invalid
      defer { if prompts { SettingsScene.raise() } }
      try await tunnel.start()
    }

    func stop() {
      Task { await tunnel.stop() }
    }

    func stopAndWait() async {
      await tunnel.stop()
      for _ in 0..<40 where tunnel.vpnStatus != .disconnected {
        try? await Task.sleep(for: .milliseconds(250))
      }
    }

    func shutdown() {}
    func observe(_ status: StatusResult) {}

    func status() async -> StatusResult {
      guard tunnel.isConnected else { return .daemonDown }
      await publishCLIEndpoint()
      do {
        let tailnets = try await tunnel.send(.status).decode([ProfileStatus].self)
        KnownTailnet.saved = tailnets.map { KnownTailnet(profile: $0.profile, name: $0.name) }
        return .ok(tailnets)
      } catch {
        return .failed(error.localizedDescription)
      }
    }

    private var publishedEndpoint: CLIEndpoint?

    /// Tells the bundled CLI where the extension's API is. Checked on every
    /// poll because the token changes whenever an edit restarts the core.
    private func publishCLIEndpoint() async {
      guard let ep = try? await tunnel.send(.cli).decode(CLIEndpoint.self),
        ep != publishedEndpoint, let file = Self.cliEndpointFile
      else { return }
      do {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ep).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        publishedEndpoint = ep
      } catch {
        NSLog("tsmux: can't write \(file.path): \(error)")
      }
    }

    /// The first of the paths the CLI reads (`AppEndpointPaths` in
    /// internal/tsmux/app.go); the App Store build's sandboxed CLI can only
    /// read the shared group container.
    private static var cliEndpointFile: URL? {
      #if DIRECT
        FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Application Support/TSMux/cli-endpoint.json")
      #else
        FileManager.default
          .containerURL(forSecurityApplicationGroupIdentifier: "4BJBDQVY6M.dev.northisup.tsmux")?
          .appendingPathComponent("cli-endpoint.json")
      #endif
    }

    /// The tunnel holds the config, and it may be off, so this is the list
    /// it last reported, kept up to date by every edit made here.
    func profileList() -> Result<[Profile], CLIError> {
      .success(KnownTailnet.saved.map { Profile(name: $0.profile, displayName: $0.name) })
    }

    func setPrefs(_ change: PrefsChange) async -> Result<ProfileStatus, CLIError> {
      await call { try await self.tunnel.send(.prefs(change)).decode(ProfileStatus.self) }
    }

    func logout(_ profile: String) async -> Result<ProfileStatus, CLIError> {
      await call { try await self.tunnel.send(.logout(profile)).decode(ProfileStatus.self) }
    }

    /// Turns the VPN on first: the tunnel is what holds the config.
    func addProfile(_ key: String, displayName: String, controlURL: String?, matchRoot: Bool)
      async -> Result<Void, CLIError>
    {
      await call {
        try await self.startTunnel()
        _ = try await self.tunnel.send(
          .addProfile(name: key, displayName: displayName, controlURL: controlURL ?? "")
        ).decode(ProfileEditResult.self)
        KnownTailnet.saved.append(KnownTailnet(profile: key, name: displayName))
      }
    }

    func renameProfile(_ key: String, to newKey: String, displayName: String) async
      -> Result<Void, CLIError>
    {
      await call {
        _ = try await self.tunnel.send(
          .renameProfile(key, to: newKey, displayName: displayName)
        ).decode(ProfileEditResult.self)
        KnownTailnet.saved = KnownTailnet.saved.map {
          $0.profile == key ? KnownTailnet(profile: newKey, name: displayName) : $0
        }
      }
    }

    /// The tunnel always logs out and deletes the saved login: nothing else
    /// can reach its state to clean up later.
    func removeProfile(_ key: String, purge: Bool) async -> Result<RemovedProfile, CLIError> {
      await call {
        let r = try await self.tunnel.send(.removeProfile(key)).decode(ProfileEditResult.self)
        KnownTailnet.saved.removeAll { $0.profile == key }
        return RemovedProfile(removed: key, purged: true, warning: r.warning)
      }
    }

    func moveProfile(_ key: String, to index: Int) async -> Result<Void, CLIError> {
      await call {
        _ = try await self.tunnel.send(.moveProfile(key, to: index)).decode(ProfileEditResult.self)
        if let i = KnownTailnet.saved.firstIndex(where: { $0.profile == key }) {
          let t = KnownTailnet.saved.remove(at: i)
          KnownTailnet.saved.insert(t, at: min(index, KnownTailnet.saved.count))
        }
      }
    }

    func setHostname(_ key: String, _ name: String) async -> Result<Void, CLIError> {
      .failure(CLIError(message: "Renaming the device isn't available in this version."))
    }

    func doctor() async -> Result<DoctorReport, CLIError> {
      .failure(CLIError(message: "Diagnostics aren't available in this version."))
    }

    func version() async -> VersionInfo? {
      VersionInfo(version: Project.version, tailscale: nil)
    }

    func pacURL() async -> String? { nil }
    func applyPAC() async -> CLIError? { nil }
    func restorePAC() -> CLIError? { nil }

    var expiryWatchInstalled: Bool { false }
    func setExpiryWatch(_ on: Bool) throws {}
    func checkExpiryNow() {}

    private func call<T>(_ body: () async throws -> T) async -> Result<T, CLIError> {
      do {
        return .success(try await body())
      } catch {
        return .failure(CLIError(message: error.localizedDescription))
      }
    }
  }
#endif

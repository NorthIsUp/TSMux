import AppKit
import Foundation
import Sparkle
import TSMuxKit
import TSMuxShell

// AppKit NSStatusItem + NSMenu, not SwiftUI MenuBarExtra: MenuBarExtra has no
// menuWillOpen hook, no per-item tooltips and no working alternates, which this
// whole UI is built on. The Settings window is SwiftUI; the menu is not.

@MainActor
final class Controller: NSObject, NSMenuDelegate {
  let model = AppModel()
  private var item: NSStatusItem?
  private let menu = NSMenu()
  private var timer: Timer?

  /// Sparkle. Started here rather than lazily: the updater has to be running to
  /// do its own scheduled background checks, not only to answer the menu item.
  private let updater = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  // MARK: launch

  /// Rows currently on screen, so a status poll can re-render them while the
  /// menu is open instead of leaving stale state under the user's cursor.
  private var liveRows: [String: MenuRowHost] = [:]
  private var hoverTimer: Timer?
  private var keyboardDriven = false
  private var lastMouse = NSPoint.zero

  /// Where the mark's lit count currently sits. Fractional mid-animation, and
  /// the animation's own start value, so a change that lands while one is
  /// running picks up from what is on screen rather than snapping.
  private var litShown: CGFloat = 0
  private var litTimer: Timer?

  func install() {
    model.onChange = { [weak self] in
      self?.updateIcon()
      self?.refreshLiveRows()
      self?.scheduleTimer()
    }
    menu.delegate = self
    // Automatic validation re-enables any item with a target+action, discarding
    // every `isEnabled = false` below.
    menu.autoenablesItems = false
    let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    i.menu = menu
    i.isVisible = true
    i.button?.imagePosition = .imageLeading
    if i.button == nil {
      NSLog("tsmux: NSStatusItem has no button — menu bar item will not appear")
    }
    item = i
    model.launchProbe()
    updateIcon()
    scheduleTimer()
    if CLI.path == nil {
      Alert.show("tsmux CLI not found", "TSMux could not find the tsmux executable to talk to.")
    }
  }

  // MARK: refresh

  private func scheduleTimer() {
    let interval: TimeInterval
    switch model.ui {
    case .starting: interval = 1
    case .ok(let ps): interval = ps.contains { $0.condition == .needsLogin } ? 1 : 5
    default: interval = 15
    }
    if let t = timer, t.timeInterval == interval, t.isValid { return }
    timer?.invalidate()
    let t = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { self.model.refresh() }
    }
    t.tolerance = 1
    // .common so the badge keeps ticking while the menu is tracking.
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  @objc private func refresh() { model.refresh() }

  // MARK: status item

  private func updateIcon() {
    guard let button = item?.button else { return }
    let ps = model.profiles
    let up = ps.filter { $0.condition == .running }.count
    let total = ps.count

    let label: String
    var badge: String?
    var dimmed = false

    if case .firstRun = model.configState {
      animateLit(to: 0, total: 0, on: button)
      button.appearsDisabled = true
      button.title = ""
      button.toolTip = "tsmux — no tailnets set up yet"
      button.setAccessibilityLabel(button.toolTip)
      return
    }

    switch model.ui {
    case .ok:
      if ps.contains(where: { $0.condition == .needsLogin }) {
        label = "tsmux, \(ps.filter { $0.condition == .needsLogin }.count) tailnets need login"
      } else if ps.contains(where: { $0.condition == .failed }) {
        label = "tsmux, \(ps.filter { $0.condition == .failed }.count) tailnets have errors"
      } else if ps.contains(where: { $0.condition == .lockedOut }) {
        label =
          "tsmux, \(ps.filter { $0.condition == .lockedOut }.count) tailnets need a tailnet-lock signature"
      } else {
        label = "tsmux, \(up) of \(total) tailnets connected"
      }
    case .starting:
      badge = "…"
      label = "tsmux, starting"
    case .down:
      dimmed = true
      label = "tsmux, not running"
    case .failed, .crashed, .cliMissing:
      label = "tsmux, can't read status"
    }

    // "5/5" is noise — everything is fine and the grid already says so. The
    // count earns its space only when some tailnet is not up.
    if case .ok = model.ui, total > 0, up < total || model.alwaysShowCount {
      badge = "\(up)/\(total)"
    }

    // Always the grid. Swapping in a warning symbol makes the app stop
    // looking like itself exactly when the user is hunting for it; the unlit
    // dots and the count already say something needs attention.
    animateLit(to: CGFloat(up), total: total, on: button)
    let image = button.image
    button.appearsDisabled = dimmed
    button.toolTip = label
    button.setAccessibilityLabel(label)

    if let badge, image != nil {
      button.attributedTitle = NSAttributedString(
        string: " \(badge)",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        ])
    } else {
      button.title = ""
    }

    // Invariant: the item is never contentless, whatever SF Symbols does.
    if button.image == nil {
      button.title = up > 0 ? "tsmux \(up)/\(total)" : "tsmux"
    }
    assert(button.image != nil || !button.title.isEmpty)
  }

  /// A spoke lighting up is a state change worth seeing, and the mark counts —
  /// so animate the count, not a dissolve between two finished images. Redraws
  /// the mark with a fractional `lit` for the length of the animation.
  ///
  /// ponytail: a 60Hz timer rather than an animatable CALayer property, which
  /// would mean replacing `button.image` with a layer-backed subview. Upgrade
  /// if this ever needs to be interruptible or frame-synced.
  private func animateLit(to target: CGFloat, total: Int, on button: NSButton) {
    litTimer?.invalidate()
    litTimer = nil
    // Also the path for a `total`/dimmed change, where the count is unmoved
    // but the mark still has to be redrawn.
    button.image = Self.gridImage(lit: litShown, total: total)
    guard litShown != target else { return }

    let from = litShown
    let started = Date()
    // 280ms read as a hard cut: the mark is 18x14pt and a spoke only travels
    // from 26% to 100% alpha, so the eye needs longer on it than a control
    // animation would take.
    let duration = 0.5
    let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak button] timer in
      guard let self, let button else { return timer.invalidate() }
      let p = min(1, Date().timeIntervalSince(started) / duration)
      let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
      MainActor.assumeIsolated {
        self.litShown = from + (target - from) * CGFloat(eased)
        button.image = Self.gridImage(lit: self.litShown, total: total)
        if p >= 1 {
          timer.invalidate()
          self.litTimer = nil
        }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    litTimer = t
  }

  private static func barImage(_ symbol: String) -> NSImage? {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 15, weight: .medium, scale: .medium))
    image?.isTemplate = true
    return image
  }

  /// The menu bar mark: a 3x3 dot grid with the top-middle dot promoted to a
  /// chevron — Tailscale's family resemblance, plus the thing tsmux adds,
  /// which is traffic leaving through several tailnets at once. Filled dots
  /// count the connected tailnets, so the mark carries the state a "2/3"
  /// badge used to. Drawn rather than an asset: it changes with the count,
  /// and a template image tints itself in both menu bar appearances.
  static func gridImage(lit litRaw: CGFloat, total: Int) -> NSImage {
    let size = NSSize(width: 18, height: 14)
    let image = NSImage(size: size, flipped: false) { _ in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      // The same multiplexer the app icon uses: tailnets on either side, each
      // on its own line, converging on one hub. A spoke is lit when that many
      // tailnets are connected, so the mark counts without any text.
      let hub = CGPoint(x: 9, y: 7)
      let cols: [CGFloat] = [2.4, 15.6]
      let rows: [CGFloat] = [2.4, 7, 11.6]
      let node: CGFloat = 1.5
      let hubR: CGFloat = 2.0

      var slots: [(CGFloat, CGFloat)] = []
      for y in rows { for x in cols { slots.append((x, y)) } }
      slots.sort { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 < b.1 }
      let dimAll = total == 0
      let lit = max(0, min(litRaw, CGFloat(slots.count)))

      ctx.setLineCap(.round)
      ctx.setLineJoin(.round)
      ctx.setLineWidth(1.35)
      for (i, p) in slots.enumerated() {
        // Fractional, so a spoke brightens through the intermediate values
        // instead of stepping: `lit` of 1.4 has spoke 0 full and spoke 1 at
        // 40%. The dot is the tailnet, the line is just its route: keep every
        // dot legible so the mark always reads as a full mux, and let the
        // unlit lines recede rather than disappear.
        let on = dimAll ? 0 : max(0, min(lit - CGFloat(i), 1))
        let lineAlpha = 0.26 + 0.74 * on
        let dotAlpha = 0.5 + 0.5 * on
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(lineAlpha).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: p.0, y: p.1))
        if abs(p.1 - hub.y) < 0.01 {
          ctx.addLine(to: hub)
        } else {
          // The app icon's bezier at menu bar scale: a smooth S with strongly
          // horizontal tangents, so the trace runs flat out of the dot and
          // arrives flat at the hub with one bend between.
          let reach = (hub.x - p.0) * 0.62
          ctx.addCurve(
            to: hub,
            control1: CGPoint(x: p.0 + reach, y: p.1),
            control2: CGPoint(x: hub.x - reach, y: hub.y))
        }
        ctx.strokePath()
        ctx.setFillColor(NSColor.black.withAlphaComponent(dotAlpha).cgColor)
        ctx.fillEllipse(
          in: CGRect(x: p.0 - node, y: p.1 - node, width: node * 2, height: node * 2))
      }

      // Two spare channels straight up and down, always dim: capacity the hub
      // has that nothing is plugged into. Same as the app icon, so the two
      // marks read as one thing.
      ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.26).cgColor)
      ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
      for y in [rows[0], rows[2]] {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: hub.x, y: y))
        ctx.addLine(to: hub)
        ctx.strokePath()
        ctx.fillEllipse(
          in: CGRect(x: hub.x - node, y: y - node, width: node * 2, height: node * 2))
      }

      ctx.setFillColor(NSColor.black.withAlphaComponent(dimAll ? 0.3 : 1).cgColor)
      ctx.fillEllipse(
        in: CGRect(x: hub.x - hubR, y: hub.y - hubR, width: hubR * 2, height: hubR * 2))
      return true
    }
    image.isTemplate = true
    return image
  }

  // MARK: menu

  func menuWillOpen(_ menu: NSMenu) {
    rebuild()
    model.refresh()
    keyboardDriven = false
    lastMouse = NSEvent.mouseLocation
    let t = Timer(timeInterval: 1 / 30, repeats: true) { _ in
      MainActor.assumeIsolated { self.trackHover() }
    }
    // .common so it keeps ticking while the menu is tracking.
    RunLoop.main.add(t, forMode: .common)
    hoverTimer = t
  }

  func menuDidClose(_ menu: NSMenu) {
    liveRows.removeAll()
    hoverTimer?.invalidate()
    hoverTimer = nil
  }

  /// Keyboard navigation only. AppKit also highlights the first item as the
  /// menu opens, with the pointer still up in the menu bar and no current
  /// event at all — invisible on an ordinary item, a painted selection on a
  /// custom-drawn one. A key press is the only highlight worth taking from
  /// here; the pointer is `trackHover`'s job.
  func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
    guard NSApp.currentEvent?.type == .keyDown else { return }
    keyboardDriven = true
    for host in liveRows.values {
      host.state.highlighted = host.enclosingMenuItem === item
    }
  }

  /// Polled, because a menu runs its own event-tracking loop: tracking areas
  /// inside it never fire, and `willHighlight` cannot be told apart from the
  /// highlight AppKit hands out at open time. Where the pointer actually is
  /// answers both. Yields to the keyboard until the pointer moves again, so
  /// arrowing away from the row the pointer happens to rest on does not leave
  /// two selections behind.
  private func trackHover() {
    let mouse = NSEvent.mouseLocation
    defer { lastMouse = mouse }
    if keyboardDriven {
      guard mouse != lastMouse else { return }
      keyboardDriven = false
    }
    for host in liveRows.values {
      host.state.highlighted = host.contains(screenPoint: mouse)
    }
  }

  /// Re-render the rows on screen. A status poll fires while the menu is
  /// tracking, so without this the tick and the uptime keep showing the state
  /// the tailnet was in when the menu opened.
  private func refreshLiveRows() {
    guard !liveRows.isEmpty else { return }
    for p in model.displayProfiles {
      guard let host = liveRows[p.profile] else { continue }
      let (symbol, color, label) = Self.appearance(p.condition, state: p.state)
      host.state.apply(
        isOn: p.isUp,
        enabled: p.isUp || p.prefs?.connected == false,
        symbol: symbol, tint: color,
        detail: p.condition == .running ? p.uptime : label)
    }
    if let host = liveRows[Self.daemonRowKey] {
      let running = model.daemonRunning
      let anyUp = model.displayProfiles.contains(where: \.isUp)
      let (symbol, color, label) = Self.daemonAppearance(model.ui, anyUp: anyUp)
      host.state.apply(
        isOn: anyUp,
        enabled: running ? model.weOwnDaemon : CLI.path != nil,
        symbol: symbol, tint: color,
        detail: running && !model.weOwnDaemon ? "started elsewhere" : label)
    }
    if let host = liveRows[Self.pacRowKey] {
      host.state.apply(
        isOn: model.pacApplied,
        enabled: model.profiles.contains { $0.condition == .running },
        symbol: "globe", tint: nil,
        detail: nil)
    }
  }

  static let daemonRowKey = "\u{0}daemon"
  static let pacRowKey = "\u{0}pac"

  static func expiryTitle(_ p: ProfileStatus) -> String {
    switch p.daysUntilExpiry ?? 0 {
    case ..<0: return "\(p.name)'s key has expired — sign in again…"
    case 0: return "\(p.name)'s key expires today — sign in again…"
    case 1: return "\(p.name)'s key expires tomorrow — sign in again…"
    case let d: return "\(p.name)'s key expires in \(d) days — sign in again…"
    }
  }

  private func rebuild() {
    menu.removeAllItems()

    switch model.configState {
    case .firstRun:
      rebuildFirstRun()
      return
    case .broken(let msg):
      rebuildBroken(msg)
      return
    case .configured:
      break
    }

    // 1. status / profile block
    switch model.ui {
    case .cliMissing:
      menu.addItem(disabled("tsmux CLI not found"))
    case .down:
      menu.addItem(disabled("tsmux is not running"))
    case .starting:
      menu.addItem(disabled("Starting tsmux… (up to 30s)"))
    case .crashed(let line):
      let mi = disabled("tsmux stopped unexpectedly")
      mi.toolTip = line
      menu.addItem(mi)
    case .failed(let msg):
      let mi = disabled("Can't read tsmux status")
      mi.toolTip = msg
      menu.addItem(mi)
    case .ok(let ps):
      if ps.isEmpty {
        menu.addItem(action("Set up your first tailnet…", #selector(addTailnet)))
      } else {
        for p in ps { menu.addItem(profileItem(p)) }
      }
    }

    // 2. attention row
    // .needsLogin now implies a usable link — a node still acquiring one reads
    // as .starting, so there is no link-less case to render here.
    if let p = model.profiles.first(where: { $0.condition == .needsLogin }),
      let url = p.authURL, !url.isEmpty
    {
      let mi = action("Log in to \(p.name)…", #selector(openLogin(_:)), symbol: "person.badge.key")
      mi.representedObject = url
      menu.addItem(mi)
    }

    // A node key expires 180 days after sign-in and cannot be renewed without
    // one, so the only useful thing to do is say so before it lapses.
    if let p = model.expiringProfiles.first, let admin = p.adminURL, !admin.isEmpty {
      let mi = action(
        Self.expiryTitle(p), #selector(openLogin(_:)), symbol: "clock.badge.exclamationmark")
      mi.representedObject = admin
      menu.addItem(mi)
    }

    menu.addItem(.separator())

    // 3. start / stop
    // The master switch. "tsmux" alone did not say that turning it off takes
    // every tailnet with it.
    let running = model.daemonRunning
    let anyOn = model.displayProfiles.contains(where: \.isUp)
    let (dSymbol, dColor, dLabel) = Self.daemonAppearance(model.ui, anyUp: anyOn)
    let (allRow, allHost) = NSMenuItem.toggleRow(
      title: "All tailnets",
      isOn: anyOn,
      enabled: running ? model.weOwnDaemon : CLI.path != nil,
      symbol: dSymbol, tint: dColor,
      detail: running && !model.weOwnDaemon ? "started elsewhere" : dLabel
    ) { [weak self] on in
      self?.setAllConnected(on)
    }
    liveRows[Self.daemonRowKey] = allHost
    menu.addItem(allRow)

    // 4. PAC toggle. Copying the PAC URL is an Advanced-submenu job: the
    // routing toggle is the thing anyone comes here for.
    // A switch, not a checkmark: it is the same kind of boolean as the three
    // rows above it. It is also the only `state` this menu ever set, and a
    // checkmark anywhere makes AppKit reserve a state column that shifts every
    // plain row's glyph — which the custom rows above cannot follow.
    let (pacRow, pacHost) = NSMenuItem.toggleRow(
      title: "Route all traffic",
      isOn: model.pacApplied,
      enabled: model.profiles.contains { $0.condition == .running },
      symbol: "globe"
    ) { [weak self] _ in
      self?.model.togglePAC()
    }
    liveRows[Self.pacRowKey] = pacHost
    menu.addItem(pacRow)

    menu.addItem(.separator())

    // 6-9. fixed tail
    menu.addItem(action("Refresh", #selector(refresh), key: "r", symbol: "arrow.clockwise"))
    menu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
    menu.addItem(advancedItem())
    menu.addItem(
      action(
        model.weOwnDaemon ? "Quit TSMux (stops tailnets)" : "Quit TSMux", #selector(quit),
        key: "q", symbol: "power"))
  }

  private func rebuildFirstRun() {
    let setup = action("Set up your first tailnet…", #selector(addTailnet))
    // Accent-coloured rather than a template glyph: this is the one thing to do.
    setup.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
    setup.image?.isTemplate = false
    menu.addItem(setup)
    menu.addItem(.separator())
    menu.addItem(advancedItem())
    menu.addItem(action("Quit TSMux", #selector(quit), key: "q", symbol: "power"))
  }

  private func rebuildBroken(_ msg: String) {
    menu.addItem(disabled("⚠ Configuration error"))
    let line = disabled(msg.split(separator: "\n").first.map(String.init) ?? msg)
    line.toolTip = msg
    menu.addItem(line)
    menu.addItem(.separator())
    menu.addItem(action("Open Configuration…", #selector(openConfig), symbol: "doc.text"))
    menu.addItem(action("Run Diagnostics…", #selector(runDoctor), symbol: "stethoscope"))
    menu.addItem(.separator())
    menu.addItem(action("Quit TSMux", #selector(quit), key: "q", symbol: "power"))
  }

  private func advancedItem() -> NSMenuItem {
    let top = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
    top.image = Self.menuGlyph("wrench.and.screwdriver")
    let sub = NSMenu()
    sub.autoenablesItems = false
    let copyPac = action("Copy PAC URL", #selector(copyPAC), symbol: "doc.on.doc")
    copyPac.isEnabled = model.profiles.contains { $0.condition == .running }
    sub.addItem(copyPac)
    sub.addItem(action("Edit config.yaml…", #selector(openConfig), symbol: "doc.text"))
    sub.addItem(action("Run Diagnostics…", #selector(runDoctor), symbol: "stethoscope"))
    sub.addItem(.separator())
    let update = action(
      "Check for Updates…", #selector(checkForUpdates), symbol: "arrow.down.circle")
    // Sparkle disables its own check while one is in flight; without
    // autoenablesItems the menu will not ask, so mirror it here.
    update.isEnabled = updater.updater.canCheckForUpdates
    sub.addItem(update)
    top.submenu = sub
    return top
  }

  /// Devices submenu. Each device is three stacked items sharing one slot:
  /// plain copies the URL, Option the IP, Shift-Option the short name. AppKit
  /// swaps them as the modifiers change, so the menu shows only one at a time.
  private func addDevices(_ p: ProfileStatus, to sub: NSMenu) {
    let devices = p.devices ?? []
    guard !devices.isEmpty else {
      sub.addItem(disabled("\(p.peers ?? 0) peers"))
      if let up = p.uptime {
        sub.addItem(disabled("connected \(up)"))
      }
      return
    }
    let root = NSMenuItem(title: "Devices (\(devices.count))", action: nil, keyEquivalent: "")
    root.image = Self.menuGlyph("laptopcomputer.and.iphone")
    let menu = NSMenu()
    menu.autoenablesItems = false

    for (i, group) in deviceGroups(devices).enumerated() {
      if i > 0 { menu.addItem(.separator()) }
      menu.addItem(disabled(group.name))
      for d in group.devices { addDeviceVariants(d, to: menu, profile: p) }
    }
    menu.addItem(.separator())
    let anyShell = devices.contains { d in
      SSHAccess.target(
        device: d.name, ips: d.ips, online: d.online, hostKeys: d.sshHostKeys, tailnet: p.profile,
        login: p.user?.loginName, socksAddr: p.socks5Proxy) != nil
    }
    menu.addItem(disabled("⌥ copy IP   ⇧⌥ copy name" + (anyShell ? "   ⌘ open shell" : "")))
    root.submenu = menu
    sub.addItem(root)
  }

  private func addDeviceVariants(_ d: Device, to menu: NSMenu, profile: ProfileStatus) {
    let dot = d.online ? "🟢" : "⚪️"
    let exit = d.exitNode == true ? "  ⇥" : ""
    let name = "\(dot)  \(d.shortName)\(exit)"
    // Holding a modifier shows the value it would copy, greyed on the right,
    // rather than naming it — the thing you are about to put on the clipboard
    // is more use than the word "IP".
    let variants: [(String?, String?)] = [
      (nil, d.url),
      (d.primaryIP, d.primaryIP),
      (d.shortName, d.shortName),
    ]
    let masks: [NSEvent.ModifierFlags] = [[], [.option], [.option, .shift]]
    // Only Tailscale SSH machines get a shell; see SSHAccess.
    let target = SSHAccess.target(
      device: d.name, ips: d.ips, online: d.online, hostKeys: d.sshHostKeys,
      tailnet: profile.profile, login: profile.user?.loginName, socksAddr: profile.socks5Proxy)
    for (i, v) in variants.enumerated() {
      let mi = NSMenuItem(title: name, action: #selector(copyValue(_:)), keyEquivalent: "")
      mi.target = self
      mi.keyEquivalentModifierMask = masks[i]
      mi.isAlternate = i > 0
      mi.isEnabled = v.1 != nil
      mi.representedObject = v.1
      if let hint = v.0 {
        mi.attributedTitle = Self.rowWithHint(name, hint)
      }
      if target != nil { mi.attributedTitle = Self.withShellGlyph(mi.attributedTitle, name) }
      mi.toolTip = [d.name, d.primaryIP, d.os].compactMap { $0 }.joined(separator: " · ")
      mi.setAccessibilityLabel(
        "\(d.shortName), \(d.online ? "online" : "offline"), copies \(v.1 ?? "nothing")")
      menu.addItem(mi)
    }
    guard let target else { return }
    let shell = NSMenuItem(title: name, action: #selector(openShell(_:)), keyEquivalent: "")
    shell.target = self
    shell.keyEquivalentModifierMask = [.command]
    shell.isAlternate = true
    shell.attributedTitle = Self.withShellGlyph(
      Self.rowWithHint(name, "ssh \(target.user)"), name)
    shell.representedObject = target
    shell.setAccessibilityLabel("\(d.shortName), open an SSH shell as \(target.user)")
    menu.addItem(shell)
  }

  @objc private func openShell(_ sender: NSMenuItem) {
    guard let target = sender.representedObject as? ShellTarget else { return }
    ShellWindows.open(target)
  }

  /// Marks a row whose machine takes an SSH shell: a terminal glyph right
  /// after the name, before any hint column.
  private static func withShellGlyph(_ title: NSAttributedString?, _ name: String)
    -> NSAttributedString
  {
    let font = NSFont.menuFont(ofSize: 0)
    let out = NSMutableAttributedString(
      attributedString: title ?? NSAttributedString(string: name, attributes: [.font: font]))
    let glyph = NSTextAttachment()
    glyph.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "SSH available")?
      .withSymbolConfiguration(.init(pointSize: font.pointSize - 2, weight: .regular))
    let mark = NSMutableAttributedString(string: "  ")
    mark.append(NSAttributedString(attachment: glyph))
    let end = (out.string as NSString).range(of: name).upperBound
    out.insert(mark, at: end == NSNotFound ? out.length : end)
    return out
  }

  /// A menu row with a secondary value pinned to the right. The tab stop is
  /// what aligns the values into a column instead of ragging after each name.
  private static func rowWithHint(_ title: String, _ hint: String) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .right, location: 300)]
    let font = NSFont.menuFont(ofSize: 0)
    let out = NSMutableAttributedString(
      string: title + "\t",
      attributes: [.font: font, .paragraphStyle: style])
    out.append(
      NSAttributedString(
        string: hint,
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular),
          .foregroundColor: NSColor.secondaryLabelColor,
          .paragraphStyle: style,
        ]))
    return out
  }

  /// Connect or disconnect one tailnet. The daemon keeps running and the
  /// other tailnets are untouched.
  /// The master switch means what it says: it connects or disconnects every
  /// tailnet, rather than stopping the daemon out from under them. Turning it
  /// on with no daemon running starts one first, since there is nothing to
  /// connect to otherwise.
  private func setAllConnected(_ on: Bool) {
    if on, !model.daemonRunning {
      model.start()
      return
    }
    for p in model.displayProfiles where p.isUp != on {
      setConnected(p.profile, on)
    }
    model.refresh()
  }

  private func setConnected(_ profile: String, _ on: Bool) {
    if let err = model.setPrefs(profile, ["--connected=\(on)"]) {
      Alert.show(on ? "Could not connect \(profile)" : "Could not disconnect \(profile)", err)
    }
  }

  private func profileItem(_ p: ProfileStatus) -> NSMenuItem {
    let (symbol, color, label) = Self.appearance(p.condition, state: p.state)
    // Each tailnet carries its own switch: they run in parallel, so turning
    // one off must not imply anything about the others. Only a tailnet that
    // has actually logged in can be toggled — for the rest the row's submenu
    // is where the login lives.
    let toggleable = p.isUp || p.prefs?.connected == false
    let (top, host) = NSMenuItem.toggleRow(
      title: p.name,
      isOn: p.isUp,
      enabled: toggleable,
      symbol: symbol, tint: color,
      detail: p.condition == .running ? p.uptime : label,
      submenu: true
    ) { [weak self] on in
      self?.setConnected(p.profile, on)
    }
    liveRows[p.profile] = host
    top.setAccessibilityLabel("\(p.name), \(label)")
    top.toolTip = p.error.map { "\(p.state): \($0)" } ?? p.state

    let sub = NSMenu()
    sub.autoenablesItems = false
    if let e = p.error, !e.isEmpty {
      let mi = action(
        "⚠︎ \(e.count > 80 ? String(e.prefix(79)) + "…" : e)", #selector(copyValue(_:)))
      mi.representedObject = e
      mi.toolTip = e
      sub.addItem(mi)
    }
    if p.condition == .needsLogin, let url = p.authURL, !url.isEmpty {
      let mi = action(
        "Log in to this tailnet…", #selector(openLogin(_:)), symbol: "person.badge.key")
      mi.representedObject = url
      sub.addItem(mi)
    }
    if p.condition == .lockedOut, let cmd = p.tailnetLock?.signCommand {
      let mi = action("Copy tailnet-lock sign command", #selector(copyValue(_:)), symbol: "lock")
      mi.representedObject = cmd
      mi.toolTip = cmd
      sub.addItem(mi)
    }
    if sub.numberOfItems > 0 { sub.addItem(.separator()) }

    sub.addItem(disabled("profile: \(p.profile)"))
    if let n = p.machineName {
      let mi = action(n, #selector(copyValue(_:)))
      mi.representedObject = n
      sub.addItem(mi)
    }
    for ip in p.ips ?? [] {
      let mi = action(ip, #selector(copyValue(_:)))
      mi.representedObject = ip
      sub.addItem(mi)
    }
    addDevices(p, to: sub)
    sub.addItem(.separator())

    let http = p.httpProxy ?? ""
    let socks = p.socks5Proxy ?? ""
    if !http.isEmpty {
      let mi = action("Copy HTTP Proxy Address", #selector(copyValue(_:)), symbol: "doc.on.doc")
      mi.representedObject = http
      sub.addItem(mi)
    }
    if !socks.isEmpty {
      let mi = action(
        "Copy SOCKS5 Proxy Address", #selector(copyValue(_:)), symbol: "doc.on.doc")
      mi.representedObject = socks
      sub.addItem(mi)
    }
    if !http.isEmpty || !socks.isEmpty {
      sub.addItem(disabled("HTTP \(http) · SOCKS5 \(socks)"))
    }
    if let sfx = p.suffixes, !sfx.isEmpty {
      sub.addItem(.separator())
      for s in sfx {
        let mi = action(s, #selector(copyValue(_:)))
        mi.representedObject = s
        sub.addItem(mi)
      }
    }
    sub.addItem(.separator())
    let settings = action(
      "Tailnet Settings…", #selector(openProfileSettings(_:)), symbol: "gearshape")
    settings.representedObject = p.profile
    sub.addItem(settings)
    top.submenu = sub
    return top
  }

  /// The master switch gets the same visual language as the tailnets it
  /// controls: connecting, running, or broken, at a glance.
  /// `anyUp` rather than the daemon's own state: a green tick beside "All
  /// tailnets" while every tailnet is stopped answers a question nobody asked.
  static func daemonAppearance(_ ui: UIState, anyUp: Bool) -> (String, NSColor?, String?) {
    switch ui {
    case .ok:
      return anyUp
        ? ("checkmark.circle.fill", .systemGreen, nil)
        : ("pause.circle", nil, "all stopped")
    case .starting: return ("arrow.triangle.2.circlepath", .systemBlue, "starting…")
    case .down: return ("pause.circle", nil, "off")
    case .crashed: return ("xmark.octagon.fill", .systemRed, "stopped unexpectedly")
    case .failed, .cliMissing: return ("xmark.octagon.fill", .systemRed, "error")
    }
  }

  /// Every status symbol resolves and, where it is coloured, draws its glyph
  /// rather than a solid lozenge. Both failures are silent at runtime: a
  /// typo'd name yields nil and the row loses its icon, and a one-colour
  /// palette on a `.fill` symbol fills the glyph too. The green tick shipped
  /// as a green disc for exactly that reason.
  static func iconSelfCheck() -> Bool {
    var symbols = ProfileStatus.Condition.allCases.map { appearance($0, state: "").0 }
    symbols += [true, false].map { daemonAppearance(.ok([]), anyUp: $0).0 }
    symbols += [UIState.starting, .down, .crashed(""), .failed(""), .cliMissing]
      .map { daemonAppearance($0, anyUp: false).0 }
    // Fractional and out-of-range lit values must still draw a mark.
    for lit in [CGFloat(-1), 0, 1.4, 6, 99] where Self.gridImage(lit: lit, total: 2).size.width == 0
    {
      NSLog("tsmux: grid mark drew nothing at lit %f", lit)
      return false
    }
    for symbol in symbols {
      guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
        NSLog("tsmux: no SF Symbol named %@", symbol)
        return false
      }
    }
    return true
  }

  /// A nil colour means "no state worth colouring": the glyph renders as a
  /// template and takes the menu's own text colour.
  static func appearance(_ c: ProfileStatus.Condition, state: String)
    -> (String, NSColor?, String)
  {
    // Symbol and tint come from the condition itself, so the menu and the
    // Settings window cannot disagree. Only the label is menu-specific: a
    // tailnet that has never run reads better as "Not started" than "Stopped".
    let label = c == .stopped && state == "NoState" ? "Not started" : c.label
    return (c.symbol, c.tint, label)
  }

  /// Every glyph in this menu, at one size and weight. Two factories — 12pt
  /// semibold for status, 13pt regular for everything else — is how the switch
  /// rows ended up with visibly smaller, heavier glyphs than the rows beneath
  /// them, in the same column.
  ///
  /// A state with a meaning worth colouring keeps its palette colour, which a
  /// template image would flatten. A neutral glyph has no colour to carry, so
  /// it goes template and picks up the menu's own text colour — the same
  /// black-or-white AppKit gives an ordinary row, rather than a hand-picked
  /// grey that only looks right in one appearance.
  private static func menuGlyph(_ symbol: String?, _ color: NSColor? = nil) -> NSImage? {
    guard let symbol else { return nil }
    var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    if let color {
      // A `.fill` symbol has a container to knock its glyph out of, and a
      // single palette colour fills glyph and container alike — which is how
      // the green tick rendered as a plain green disc. The second colour is
      // the glyph.
      let palette = symbol.hasSuffix(".fill") ? [NSColor.white, color] : [color]
      config = config.applying(NSImage.SymbolConfiguration(paletteColors: palette))
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    image?.isTemplate = color == nil
    return image
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    mi.isEnabled = false
    return mi
  }

  private func action(
    _ title: String, _ sel: Selector, key: String = "", symbol: String? = nil
  ) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    mi.target = self
    mi.image = Self.menuGlyph(symbol)
    return mi
  }

  // MARK: actions

  @objc private func start() { model.start() }
  @objc private func stop() { model.stop() }
  @objc private func togglePAC() { model.togglePAC() }
  @objc private func quit() { NSApp.terminate(nil) }

  /// An accessory app has no windows to come forward with, so the update panel
  /// would open behind whatever is frontmost.
  @objc private func checkForUpdates() {
    NSApp.activate()
    updater.checkForUpdates(nil)
  }

  @objc private func openSettings() {
    SettingsScene.open()
  }

  @objc private func addTailnet() {
    model.selectedTab = .accounts
    model.pendingAdd = true
    SettingsScene.open()
  }

  @objc private func openProfileSettings(_ sender: NSMenuItem) {
    model.selectedTab = .accounts
    model.selectedProfile = sender.representedObject as? String
    SettingsScene.open()
  }

  @objc private func copyPAC() {
    guard let url = CLI.pacURL() else {
      Alert.show("Could not get the PAC URL", "tsmux reported no details.")
      return
    }
    copy(url)
  }

  @objc private func openLogin(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
    if !NSWorkspace.shared.open(url) { Alert.show("Could not open the login page", s) }
  }

  @objc private func copyValue(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String else { return }
    copy(s)
  }

  /// Never invents a file: with no config the Add-tailnet sheet is the answer.
  @objc private func openConfig() {
    let file = ConfigPath.file
    guard FileManager.default.fileExists(atPath: file.path) else {
      addTailnet()
      return
    }
    if !NSWorkspace.shared.open(file) {
      Alert.show("Could not open the configuration file", file.path)
    }
  }

  @objc private func runDoctor() {
    let (data, err, code) = CLI.run(["--json", "doctor"], timeout: 30)
    // doctor exits 1 when it merely found problems, so read the JSON not the code.
    if let report = try? JSONDecoder().decode(DoctorReport.self, from: data) {
      let problems = report.problems ?? []
      Alert.show(
        problems.isEmpty ? "No problems found" : "\(problems.count) problem(s) found",
        ([report.config] + problems).joined(separator: "\n\n"))
      return
    }
    Alert.show("Diagnostics failed", code == 0 ? "tsmux produced no report." : CLI.message(err))
  }

  func shutdown() {
    timer?.invalidate()
    model.shutdown()
  }

  // MARK: helpers

  private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    guard let button = item?.button else { return }
    button.image = nil
    button.title = "Copied"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      MainActor.assumeIsolated { self.updateIcon() }
    }
  }
}

enum ConfigPath {
  static var file: URL {
    let base =
      ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? ("~/.config" as NSString).expandingTildeInPath
    return URL(fileURLWithPath: base)
      .appendingPathComponent("tsmux")
      .appendingPathComponent("config.yaml")
  }
}

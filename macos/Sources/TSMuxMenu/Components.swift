import AppKit
import SwiftUI
import TSMuxKit

// Shared bits of the Settings window. Kept dumb: no state beyond a copy flash.

struct CopyButton: View {
  let value: String
  @State private var copied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
    }
    .buttonStyle(.borderless)
    .help("Copy")
    .accessibilityLabel(copied ? "Copied" : "Copy \(value)")
    .disabled(value.isEmpty)
  }
}

/// Read-only value + copy button, the shape Tailscale uses for a search domain.
struct CopyableValue: View {
  let value: String
  var monospaced = false

  var body: some View {
    HStack(spacing: 6) {
      Text(value)
        .font(monospaced ? .system(.body, design: .monospaced) : .body)
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      CopyButton(value: value)
    }
  }
}

/// The app's one status glyph. The menu rows draw the same symbol at the same
/// optical size, so a tailnet looks the same in the menu bar and in Settings —
/// which it did not when this was a plain coloured dot.
struct StatusDot: View {
  let condition: ProfileStatus.Condition
  var body: some View {
    Image(systemName: condition.symbol)
      .symbolRenderingMode(condition.tint == nil ? .monochrome : .palette)
      .foregroundStyle(glyph, container)
      // 11pt to match the menu rows: a circle inks its full point size where
      // line art inks ~2pt less, so the circles are set smaller to match.
      .font(.system(size: 11))
      .accessibilityLabel(condition.label)
  }

  /// A `.fill` symbol knocks its glyph out of its container, so one palette
  /// colour would fill both and the tick would vanish into a solid disc.
  private var glyph: Color {
    guard let tint = condition.tint else { return untinted }
    return condition.symbol.hasSuffix(".fill") ? .white : Color(tint)
  }

  private var container: Color { condition.tint.map { Color($0) } ?? untinted }

  /// An untinted glyph has no state worth colouring and follows the text
  /// around it — including when the system recolours a selected sidebar row.
  private var untinted: Color { .primary }
}

extension ProfileStatus.Condition {
  /// One vocabulary for every surface: the menu's rows, its mark's tooltip and
  /// the Settings window all read these, so a state cannot look like one thing
  /// in the menu and another in a window.
  var symbol: String {
    switch self {
    case .running: return "checkmark.circle.fill"
    case .starting: return "arrow.triangle.2.circlepath"
    case .needsLogin: return "exclamationmark.triangle.fill"
    case .needsApproval: return "hourglass"
    case .stopped: return "pause.circle"
    case .failed: return "xmark.octagon.fill"
    }
  }

  /// nil means "no state worth colouring" — the glyph takes the surrounding
  /// text colour instead of a hand-picked grey.
  var tint: NSColor? {
    switch self {
    case .running: return .systemGreen
    case .starting: return .systemBlue
    case .needsLogin: return .systemYellow
    case .needsApproval: return .systemOrange
    case .stopped: return nil
    case .failed: return .systemRed
    }
  }

  var label: String {
    switch self {
    case .running: return "Connected"
    case .starting: return "Connecting…"
    case .needsLogin: return "Needs login"
    case .needsApproval: return "Waiting for approval"
    case .stopped: return "Stopped"
    case .failed: return "Error"
    }
  }
}

/// D9: initials in a tinted circle. No image fetch for decoration in a tool
/// whose whole point is scoped traffic.

/// The one treatment for every capability tsmux structurally cannot offer:
/// Tailscale's label at full contrast, an "Unavailable" capsule where the
/// control would be, and the reason spelled out under it.
struct UnavailableRow: View {
  let title: String
  let note: String
  var control: AnyView?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        if let control {
          control.disabled(true)
        }
        Text("Unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      Text(note)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .help(note)
    .accessibilityHint(note)
  }
}

enum Unavailable {
  static let runAsExitNode = """
    Unavailable. Serving as an exit node means capturing and forwarding other \
    devices' traffic, which needs a system VPN interface. tsmux runs each tailnet \
    in userspace with no VPN device — the same choice that lets it run all your \
    tailnets at the same time. Using an exit node still works, per tailnet, under \
    Accounts.
    """

  static let vpnOnDemand = """
    Unavailable. On Demand turns a system VPN profile on and off as you change \
    networks. tsmux installs no system VPN profile, so there is nothing to switch — \
    your tailnets are simply always connected, on every network.
    """

  static let tailnetLock = """
    Unavailable. The Tailscale library tsmux embeds (v1.102.4) exposes no \
    tailnet-lock API, so tsmux can't sign or list locked nodes. Manage lock from \
    the admin console, or from the official Tailscale client on another device.
    """
}

@MainActor
func openURLString(_ s: String) {
  guard let url = URL(string: s) else { return }
  NSWorkspace.shared.open(url)
}

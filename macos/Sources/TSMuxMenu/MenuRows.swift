import AppKit
import SwiftUI

/// The mutable half of a switch row. The controller holds one of these per
/// row and writes to it; SwiftUI re-renders. A status poll fires while the
/// menu is tracking, so the row has to change state without being rebuilt.
@Observable
@MainActor
final class MenuRowState {
  var title: String
  var isOn: Bool
  var enabled: Bool
  var leading: NSImage?
  var detail: String?
  let submenu: Bool
  var highlighted = false

  init(
    title: String, isOn: Bool, enabled: Bool, leading: NSImage?, detail: String?,
    submenu: Bool
  ) {
    self.title = title
    self.isOn = isOn
    self.enabled = enabled
    self.leading = leading
    self.detail = detail
    self.submenu = submenu
  }

  /// State only, never geometry: a re-layout while the menu is tracking drops
  /// whatever submenu is open under the pointer.
  func apply(isOn: Bool, enabled: Bool, leading: NSImage?, detail: String?) {
    self.isOn = isOn
    self.enabled = enabled
    self.leading = leading
    self.detail = detail
  }
}

/// A menu row carrying a real switch, for the things that are genuinely
/// on/off. A verb ("Stop tsmux") makes the reader work out the current state
/// from the word; a switch shows it.
struct MenuRow: View {
  @Bindable var state: MenuRowState
  let onToggle: (Bool) -> Void

  var body: some View {
    HStack(spacing: 5) {
      // A fixed image column, so these titles line up with the titles of
      // ordinary NSMenuItems rather than shifting per glyph width. Height is
      // pinned too, or a glyph swapped in while the menu is tracking resizes
      // the row and takes any open submenu with it.
      Group {
        if let img = state.leading {
          Image(nsImage: img).resizable().scaledToFit()
        }
      }
      .frame(width: 16, height: 16)

      Text(state.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(state.highlighted ? Color(.selectedMenuItemTextColor) : .primary)

      if let d = state.detail, !d.isEmpty {
        Text(d)
          .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize - 2))
          .monospacedDigit()
          .foregroundStyle(
            state.highlighted
              ? Color(.selectedMenuItemTextColor).opacity(0.75) : .secondary)
      }

      Spacer(minLength: 4)

      Toggle("", isOn: toggleBinding)
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
        .disabled(!state.enabled)

      // A custom view suppresses AppKit's own disclosure arrow, so rows that
      // open a submenu draw their own. The column is always reserved, visible
      // or not, otherwise the switches sit at two different x positions
      // depending on whether a row happens to have a submenu.
      Text("\u{203A}")
        .foregroundStyle(state.highlighted ? Color(.selectedMenuItemTextColor) : .primary)
        .opacity(state.submenu ? 1 : 0)
        .frame(width: 8)
    }
    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
    // Matches where AppKit indents an ordinary menu item's image. Measured
    // against the neighbouring rows — there is no public metric for it.
    .padding(.leading, 23)
    .padding(.trailing, 12)
    .frame(height: MenuRow.height)
    .frame(maxWidth: .infinity)
    // A custom view draws none of AppKit's row chrome, so the selection
    // background has to be drawn here or the row stays stubbornly plain
    // while every other item highlights.
    .background {
      if state.highlighted {
        RoundedRectangle(cornerRadius: 5)
          .fill(Color(.selectedContentBackgroundColor))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
      }
    }
  }

  static let height: CGFloat = 26

  private var toggleBinding: Binding<Bool> {
    Binding(
      get: { state.isOn },
      set: { on in
        // The menu stays open: flipping one tailnet is rarely the only thing
        // you came to do, and closing it forces a reopen to see the result.
        state.isOn = on
        onToggle(on)
      })
  }
}

/// Hosts a `MenuRow` in a menu item, and answers where it is on screen.
///
/// A menu runs its own event-tracking loop: tracking areas inside it never
/// fire, so the row cannot work out its own hover state and the controller
/// polls the pointer instead.
final class MenuRowHost: NSHostingView<MenuRow> {
  let state: MenuRowState

  init(state: MenuRowState, onToggle: @escaping (Bool) -> Void) {
    self.state = state
    super.init(rootView: MenuRow(state: state, onToggle: onToggle))
    // Empty, so the host takes the frame it is given instead of shrinking to
    // the row's content. Left at the default it reports an intrinsic size,
    // `maxWidth: .infinity` collapses to fit-content, and every switch lands
    // at a different x depending on how long that row's text happens to be.
    sizingOptions = []
    // A menu item view is sized from its frame, not from its constraints:
    // with an empty frame AppKit lays out a zero-height row and the item
    // vanishes. The menu is as wide as its widest item, so the row has to
    // follow that width or the selection stops short of the menu's edge.
    frame = NSRect(x: 0, y: 0, width: 264, height: MenuRow.height)
    autoresizingMask = [.width]
  }

  @MainActor required init(rootView: MenuRow) { fatalError("not used") }
  required init?(coder: NSCoder) { fatalError("not used") }

  /// Whether the pointer, in screen coordinates, is over this row.
  @MainActor func contains(screenPoint: NSPoint) -> Bool {
    guard let window else { return false }
    return bounds.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
  }
}

extension NSMenuItem {
  /// Builds a menu item whose entire row is a switch.
  @MainActor static func toggleRow(
    title: String,
    isOn: Bool,
    enabled: Bool = true,
    leading: NSImage? = nil,
    detail: String? = nil,
    submenu: Bool = false,
    onToggle: @escaping (Bool) -> Void
  ) -> (item: NSMenuItem, host: MenuRowHost) {
    let state = MenuRowState(
      title: title, isOn: isOn, enabled: enabled, leading: leading, detail: detail,
      submenu: submenu)
    let host = MenuRowHost(state: state, onToggle: onToggle)
    let mi = NSMenuItem()
    mi.view = host
    return (mi, host)
  }
}

import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// The few places the iOS and macOS builds of this app differ.
enum Pasteboard {
  static func copy(_ s: String) {
    #if os(iOS)
      UIPasteboard.general.string = s
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(s, forType: .string)
    #endif
  }
}

extension View {
  func inlineTitle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }

  func urlEntry() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.never).keyboardType(.URL)
    #else
      self
    #endif
  }

  func nameEntry() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.words)
    #else
      self
    #endif
  }
}

import SwiftUI
import TSMuxShell

/// A shell pushed from a device row; the row only offers one when there's a
/// machine to open.
struct ShellScreen: View {
  let target: ShellTarget

  var body: some View {
    ShellView(target: target)
      .ignoresSafeArea(.container, edges: .bottom)
      .navigationTitle(String(target.device.split(separator: ".").first ?? ""))
      .navigationBarTitleDisplayMode(.inline)
  }
}

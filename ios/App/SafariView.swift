import SwiftUI

#if os(iOS)
  import SafariServices
#endif

#if os(iOS)
  /// Sign-in pages open in-app rather than in Safari, so the app is still on
  /// screen to notice the tailnet come up and close the page itself. Tailscale's
  /// login never redirects to a callback, which rules out ASWebAuthenticationSession.
  struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
      SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
  }

  extension View {
    /// Presents the sign-in page while `url` is set; dismissing clears it.
    func signInSheet(_ url: Binding<URL?>) -> some View {
      sheet(
        isPresented: Binding(
          get: { url.wrappedValue != nil }, set: { if !$0 { url.wrappedValue = nil } })
      ) {
        if let u = url.wrappedValue { SafariView(url: u).ignoresSafeArea() }
      }
    }
  }
#else
  extension View {
    /// A menu bar panel can't hold a browser, so the page opens in the default
    /// browser; the tailnet coming up is noticed the same way either way.
    func signInSheet(_ url: Binding<URL?>) -> some View {
      onChange(of: url.wrappedValue) { _, new in
        guard let new else { return }
        NSWorkspace.shared.open(new)
        url.wrappedValue = nil
      }
    }
  }
#endif

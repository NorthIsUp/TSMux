import Foundation

/// Where TSMux lives, for both apps' About links.
public enum Project {
  public static let repo = URL(string: "https://github.com/NorthIsUp/TSMux")!
  public static let issues = URL(string: "https://github.com/NorthIsUp/TSMux/issues/new")!
  public static let privacy = URL(
    string: "https://github.com/NorthIsUp/TSMux/blob/main/PRIVACY.md")!
  public static let releaseNotes = URL(string: "https://github.com/NorthIsUp/TSMux/releases")!

  /// "0.1.2 (202610070537)" from the bundle's Info.plist.
  public static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let short = info["CFBundleShortVersionString"] as? String ?? "?"
    guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
    return "\(short) (\(build))"
  }
}

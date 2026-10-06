import Foundation

/// Adding a tailnet, shared by both apps: sign in first, name it after. Its
/// real name is only known once its node has logged in, so the node starts
/// under a placeholder key and is renamed at the end.
public struct AddFlow: Sendable {
  public enum Step: Equatable, Sendable {
    case connecting
    case waitingForLink
    case signIn(URL)
    case needsApproval(admin: URL?)
    case failed(String)
    case signedIn(suggestedName: String)
  }

  public static let placeholderName = "New tailnet"

  private var openedAuthURL: String?

  public init() {}

  /// `new`, or the first `new-N` nothing else holds.
  public static func placeholderKey(taken: (String) -> Bool) -> String {
    var key = "new"
    while taken(key) { key = Slug.bump(key) }
    return key
  }

  public static func step(_ p: ProfileStatus?) -> Step {
    guard let p else { return .connecting }
    switch p.condition {
    // A locked-out node has signed in; naming it doesn't need connectivity.
    case .running, .lockedOut:
      return .signedIn(
        suggestedName: Slug.suggestedName(tailnet: p.tailnet, magicDNSSuffix: p.magicDNSSuffix))
    case .needsApproval: return .needsApproval(admin: p.adminURL.flatMap(URL.init(string:)))
    case .failed: return .failed(p.error ?? "Failed")
    case .needsLogin:
      return p.authURL.flatMap(URL.init(string:)).map(Step.signIn) ?? .waitingForLink
    // `condition` folds a link-less NeedsLogin into .starting; here it's worth telling apart.
    case .starting, .stopped: return p.state == "NeedsLogin" ? .waitingForLink : .connecting
    }
  }

  /// The sign-in link to open by itself: each new link once, so closing the
  /// page doesn't reopen it, but a fresh link (a re-registration) does.
  public mutating func autoOpen(_ step: Step) -> URL? {
    guard case .signIn(let url) = step, url.absoluteString != openedAuthURL else { return nil }
    openedAuthURL = url.absoluteString
    return url
  }

  /// Whether a sign-in page was ever opened, so cancelling may throw away a
  /// login the user already did.
  public var signInStarted: Bool { openedAuthURL != nil }
}

extension AddFlow.Step {
  public var headline: String {
    switch self {
    case .connecting: "Connecting to the coordination server…"
    case .waitingForLink: "Waiting for a sign-in link…"
    case .signIn: "Sign in to add your tailnet."
    case .needsApproval: "Signed in. Waiting for a tailnet admin to approve this device…"
    case .failed(let message): message
    case .signedIn: "Signed in."
    }
  }

  public var isWaiting: Bool {
    switch self {
    case .connecting, .waitingForLink, .signIn, .needsApproval: true
    case .failed, .signedIn: false
    }
  }
}

import SwiftUI

/// Who to log in as, then the shell. Tailscale SSH hosts need only the user
/// name; a password is for plain OpenSSH hosts and is never stored.
public struct ShellLauncher: View {
  public struct Target: Sendable, Hashable {
    public var device: String  // MagicDNS name, the key for remembered users
    public var host: String  // what to dial: a Tailscale IP or the name
    public var socksAddr: String
    public var hostKeys: [String]
    public var tailnet: String

    public init(
      device: String, host: String, socksAddr: String, hostKeys: [String], tailnet: String
    ) {
      self.device = device
      self.host = host
      self.socksAddr = socksAddr
      self.hostKeys = hostKeys
      self.tailnet = tailnet
    }
  }

  let target: Target
  @State private var user: String
  @State private var password = ""
  @State private var request: SSHRequest?

  public init(target: Target) {
    self.target = target
    _user = State(initialValue: SSHUsers.last(for: target.device))
  }

  public var body: some View {
    if let request {
      ShellView(request: request, tailnet: target.tailnet)
    } else {
      form
    }
  }

  private var form: some View {
    Form {
      Section {
        TextField("User", text: $user)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
        SecureField("Password (only for non-Tailscale SSH hosts)", text: $password)
      } footer: {
        Text(
          target.hostKeys.isEmpty
            ? "This device doesn't advertise Tailscale SSH, so you'll be asked to trust its host key."
            : "This device runs Tailscale SSH: your tailnet identity signs you in."
        )
      }
      Section {
        Button("Connect") { connect() }
          .disabled(user.isEmpty)
          .keyboardShortcut(.defaultAction)
      }
    }
    .formStyle(.grouped)
    .onSubmit(connect)
  }

  private func connect() {
    guard !user.isEmpty else { return }
    SSHUsers.remember(user, for: target.device)
    request = SSHRequest(
      socksAddr: target.socksAddr, host: target.host, user: user, hostKeys: target.hostKeys,
      password: password.isEmpty ? nil : password)
  }
}

/// The last user name per device, with the most recent one as the default for
/// devices never connected to.
enum SSHUsers {
  private static let key = "sshUsers"
  private static let lastKey = "sshLastUser"

  static func last(for device: String) -> String {
    let byDevice = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    return byDevice[device] ?? UserDefaults.standard.string(forKey: lastKey) ?? ""
  }

  static func remember(_ user: String, for device: String) {
    var byDevice = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    byDevice[device] = user
    UserDefaults.standard.set(byDevice, forKey: key)
    UserDefaults.standard.set(user, forKey: lastKey)
  }
}

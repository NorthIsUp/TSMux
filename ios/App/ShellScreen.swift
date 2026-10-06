import SwiftUI
import TSMuxKit
import TSMuxShell

/// The shared shell launcher, pushed from a device row.
struct ShellScreen: View {
  let device: Device
  let tailnet: ProfileStatus

  var body: some View {
    Group {
      if let socks = tailnet.socks5Proxy {
        ShellLauncher(
          target: .init(
            device: device.name, host: device.primaryIP ?? device.name, socksAddr: socks,
            hostKeys: device.sshHostKeys ?? [], tailnet: tailnet.profile))
      } else {
        ContentUnavailableView("\(tailnet.name) isn't connected", systemImage: "network.slash")
      }
    }
    .navigationTitle(device.shortName)
    .navigationBarTitleDisplayMode(.inline)
  }
}

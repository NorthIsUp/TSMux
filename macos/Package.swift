// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TSMuxMenu",
  platforms: [.macOS("26.0")],
  products: [
    // The menu and Settings window for both Mac apps, built from
    // ios/project.yml: the App Store one runs the tailnets in its packet
    // tunnel, the Direct one (../macos/Direct) in the tsmux daemon.
    .library(name: "TSMuxMenuKit", targets: ["TSMuxMenuKit"])
  ],
  dependencies: [
    .package(path: "../TSMuxKit"),
    .package(path: "../TSMuxShell"),
  ],
  targets: [
    .target(
      name: "TSMuxMenuKit",
      dependencies: [
        .product(name: "TSMuxKit", package: "TSMuxKit"),
        .product(name: "TSMuxShell", package: "TSMuxShell"),
      ],
      path: "Sources/TSMuxMenuKit"
    )
  ]
)

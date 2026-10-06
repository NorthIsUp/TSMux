// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TSMuxKit",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "TSMuxKit", targets: ["TSMuxKit"])],
  targets: [
    .target(name: "TSMuxKit"),
    .testTarget(
      name: "TSMuxKitTests", dependencies: ["TSMuxKit"], resources: [.copy("status.json")]),
  ]
)

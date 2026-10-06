// swift-tools-version: 6.0
import PackageDescription

// The SSH shell both apps embed: the Go client (TSMuxSSH.xcframework, built by
// `mise run ssh:lib`) under a SwiftTerm terminal view.
let package = Package(
  name: "TSMuxShell",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "TSMuxShell", targets: ["TSMuxShell"])],
  dependencies: [
    // 1.12 added a Metal renderer, which needs the separately downloaded Metal
    // toolchain on every build machine; the CoreText renderer is enough here.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.11.0"))
  ],
  targets: [
    .binaryTarget(name: "TSMuxSSH", path: "TSMuxSSH.xcframework"),
    .target(
      name: "TSMuxShell",
      dependencies: ["TSMuxSSH", .product(name: "SwiftTerm", package: "SwiftTerm")]
    ),
    .testTarget(name: "TSMuxShellTests", dependencies: ["TSMuxShell"]),
  ]
)

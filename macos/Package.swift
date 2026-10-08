// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TSMuxMenu",
  platforms: [.macOS("26.0")],
  products: [
    // The menu and Settings window, for the App Store app too, which runs the
    // tailnets in its packet tunnel instead of a daemon.
    .library(name: "TSMuxMenuKit", targets: ["TSMuxMenuKit"])
  ],
  dependencies: [
    // Auto-update. The framework ships as a binary xcframework, so
    // scripts/build-app.sh copies it into Contents/Frameworks by hand —
    // SwiftPM links it but will not populate a bundle it did not assemble.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
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
    ),
    .executableTarget(
      name: "TSMuxMenu",
      dependencies: [
        "TSMuxMenuKit",
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "TSMuxKit", package: "TSMuxKit"),
      ],
      path: "Sources/TSMuxMenu",
      // Each flag needs its own -Xlinker: these go through swiftc, which does
      // not know -rpath itself.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
    ),
  ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TSMuxMenu",
  platforms: [.macOS("26.0")],
  dependencies: [
    // Auto-update. The framework ships as a binary xcframework, so
    // scripts/build-app.sh copies it into Contents/Frameworks by hand —
    // SwiftPM links it but will not populate a bundle it did not assemble.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
  ],
  targets: [
    .executableTarget(
      name: "TSMuxMenu",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      path: "Sources/TSMuxMenu",
      // Each flag needs its own -Xlinker: these go through swiftc, which does
      // not know -rpath itself.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
    )
  ]
)

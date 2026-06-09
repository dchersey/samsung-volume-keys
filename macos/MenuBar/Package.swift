// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "G8Volume",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "G8Volume",
      path: "Sources/G8Volume"
    )
  ]
)

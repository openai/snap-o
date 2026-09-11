// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SnapODeviceClient",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "SnapODeviceClient", targets: ["SnapODeviceClient"])
  ],
  dependencies: [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
  ],
  targets: [
    .target(name: "SnapODeviceClient", dependencies: ["ZIPFoundation"]),
    .testTarget(
      name: "SnapODeviceClientTests",
      dependencies: ["SnapODeviceClient", "ZIPFoundation"]
    )
  ]
)

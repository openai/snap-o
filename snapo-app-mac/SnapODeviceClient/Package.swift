// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SnapODeviceClient",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "SnapODeviceClient", targets: ["SnapODeviceClient"])
  ],
  targets: [
    .target(name: "SnapODeviceClient"),
    .testTarget(
      name: "SnapODeviceClientTests",
      dependencies: ["SnapODeviceClient"]
    )
  ]
)

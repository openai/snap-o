import Foundation
import SnapODeviceClient

extension InspectorID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
  static let sample = Self(rawValue: "sample")
}

func testPluginRegistry() throws -> InspectorPluginRegistry {
  try InspectorPluginRegistry(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../inspectors/dist"))
}

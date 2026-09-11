import Foundation
import SnapODeviceClient

extension InspectorID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
  static let sample = Self(rawValue: "sample")
}

func testManifest(pid: Int, kinds: [InspectorID], version: Int = 4) -> InspectorProcessMetadata {
  let record: [String: Any] = [
    "version": 1, "pid": pid, "processName": "com.example.demo\(pid)", "androidUserId": 0,
    "app": [
      "packageName": "com.example.demo\(pid)", "name": "Demo \(pid)", "revision": "1",
      "inspectors": kinds.map { ["id": $0.rawValue, "name": $0.rawValue, "protocolVersion": version] }
    ]
  ]
  return try! JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
}

func testPluginRegistry() throws -> InspectorPluginRegistry {
  try InspectorPluginRegistry(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../inspectors/dist"))
}

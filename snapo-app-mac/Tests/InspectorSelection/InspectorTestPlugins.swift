import Foundation
import SnapODeviceClient

extension InspectorID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
  static let sample = Self(rawValue: "sample")
}

func testManifest(pid: Int, kinds: [InspectorID], version: Int = 4) -> InspectorProcessMetadata {
  let record: [String: Any] = [
    "processIdentity": "boot:\(pid):1",
    "version": 1, "pid": pid, "processName": "com.example.demo\(pid)", "androidUserId": 0,
    "app": [
      "packageName": "com.example.demo\(pid)", "name": "Demo \(pid)", "revision": "1",
      "inspectors": kinds.map { kind -> [String: Any] in
        var descriptor: [String: Any] = ["id": kind.rawValue, "name": kind.rawValue, "protocolVersion": version]
        if kind == .tweaks {
          descriptor["frontend"] = ["assetPath": "snapo/inspectors/tweaks/frontend.zip", "hostApiVersion": 1]
        }
        return descriptor
      }
    ]
  ]
  return try! JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
}

func testPluginRegistry() throws -> InspectorPluginRegistry {
  try InspectorPluginRegistry(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("../inspectors/dist"))
}

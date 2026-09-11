import Foundation

extension PluginID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
  static let sample = Self(rawValue: "sample")
}

func testManifest(pid: Int, kinds: [PluginID], version: Int = 4, includeFrontend: Bool = true) -> PluginProcessMetadata {
  let record: [String: Any] = [
    "processIdentity": "boot:\(pid):1",
    "version": 1, "pid": pid, "processName": "com.example.demo\(pid)", "androidUserId": 0,
    "app": [
      "packageName": "com.example.demo\(pid)", "name": "Demo \(pid)", "revision": "1",
      "inspectors": kinds.map { kind -> [String: Any] in
        var descriptor: [String: Any] = ["id": kind.rawValue, "name": kind.rawValue, "protocolVersion": version]
        if includeFrontend {
          descriptor["frontend"] = ["assetPath": "snapo/inspectors/\(kind.rawValue)/frontend.zip", "hostApiVersion": 1]
        }
        return descriptor
      }
    ]
  ]
  return try! JSONDecoder().decode(PluginProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
}

func testProcessMetadata(pid: Int, kinds: [PluginID], version: Int = 4, includeFrontend: Bool = true) -> PluginMetadata.Process {
  var metadata = PluginMetadata()
  metadata.applyPackageMetadata(
    testManifest(pid: pid, kinds: kinds, version: version, includeFrontend: includeFrontend), kind: kinds.first ?? .network
  )
  return metadata.process
}

import Foundation

extension ToolID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
  static let sample = Self(rawValue: "sample")
}

func testManifest(pid: Int, kinds: [ToolID], version: Int? = 4, includeFrontend: Bool = true) -> ToolProcessMetadata {
  let record: [String: Any] = [
    "processIdentity": "boot:\(pid):1",
    "version": 1, "pid": pid, "processName": "com.example.demo\(pid)", "androidUserId": 0,
    "app": [
      "packageName": "com.example.demo\(pid)", "name": "Demo \(pid)", "revision": "1",
      "inspectors": kinds.map { kind -> [String: Any] in
        var descriptor: [String: Any] = ["id": kind.rawValue, "name": kind.rawValue]
        if let version { descriptor["protocolVersion"] = version }
        if includeFrontend {
          descriptor["frontend"] = ["assetPath": "snapo/inspectors/\(kind.rawValue)/frontend.zip", "hostApiVersion": 1]
        }
        return descriptor
      }
    ]
  ]
  return try! JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
}

func testProcessMetadata(pid: Int, kinds: [ToolID], version: Int? = 4, includeFrontend: Bool = true) -> ToolMetadata.Process {
  var metadata = ToolMetadata()
  metadata.applyPackageMetadata(
    testManifest(pid: pid, kinds: kinds, version: version, includeFrontend: includeFrontend), kind: kinds.first ?? .network
  )
  return metadata.process
}

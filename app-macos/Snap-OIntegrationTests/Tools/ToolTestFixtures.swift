import Foundation
#if canImport(Snap_O) && !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif

extension ToolID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
  static let sample = Self(rawValue: "sample")
}

func testManifest(pid: Int, kinds: [ToolID], includeFrontend: Bool = true, toolOrder: [ToolID]? = nil) -> ToolProcessMetadata {
  let record: [String: Any] = [
    "processIdentity": "boot:\(pid):1",
    "version": 1, "pid": pid, "processName": "com.example.demo\(pid)", "androidUserId": 0,
    "app": [
      "packageName": "com.example.demo\(pid)", "name": "Demo \(pid)", "revision": "1",
      "toolOrder": toolOrder.map { $0.map(\.rawValue) } as Any? ?? NSNull(),
      "inspectors": kinds.map { kind -> [String: Any] in
        var descriptor: [String: Any] = ["id": kind.rawValue, "name": kind.rawValue]
        if includeFrontend {
          descriptor["frontend"] = ["assetPath": "snapo/inspectors/\(kind.rawValue)/frontend.zip", "hostApiVersion": 1]
        }
        return descriptor
      }
    ]
  ]
  return try! JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
}

func testProcessMetadata(pid: Int, kinds: [ToolID], includeFrontend: Bool = true) -> ToolMetadata.Process {
  var metadata = ToolMetadata()
  metadata.applyPackageMetadata(
    testManifest(pid: pid, kinds: kinds, includeFrontend: includeFrontend), kind: kinds.first ?? .network
  )
  return metadata.process
}

func selectionApp(
  _ pid: Int = 10, kinds: [ToolID] = [.network, .tweaks],
  process: String? = "com.example.demo", device: String = "phone", user: Int? = 0,
  package: String? = "com.example.demo", connectedKinds: [ToolID]? = nil, processIdentity: String? = nil
) -> InspectableApp {
  let manifest = testManifest(pid: pid, kinds: kinds)
  var record = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
  if let processIdentity { record["processIdentity"] = processIdentity }
  record["androidUserId"] = user as Any? ?? NSNull()
  record["processName"] = process as Any? ?? NSNull()
  var packageRecord = record["app"] as! [String: Any]
  packageRecord["packageName"] = package ?? "com.example.demo"
  record["app"] = packageRecord
  let identity = ToolProcessIdentity(metadata: try! JSONDecoder().decode(
    ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record)
  ))
  let metadata = ToolMetadata.Process(
    name: "Demo", packageName: package, processName: process,
    verifiedIdentity: identity, tools: manifest.app!.tools
  )
  return InspectableApp(
    id: "\(device):pid:\(pid)", pid: pid, deviceId: device, deviceDisplayTitle: "Phone",
    tools: kinds.map {
      AppToolOption(
        kind: $0, server: .init(deviceId: device, socketName: "snapo_\($0.rawValue)_\(pid)"),
        isConnected: connectedKinds?.contains($0) ?? true, compatibility: .supported
      )
    }, metadata: metadata
  )
}

func selected(_ kind: ToolID = .network) -> ToolSelection {
  var owner = ToolSelection()
  owner.reconcile([selectionApp()])
  owner.selectTool(selectionApp(), option: selectionApp().tools.first { $0.kind == kind }!)
  return owner
}

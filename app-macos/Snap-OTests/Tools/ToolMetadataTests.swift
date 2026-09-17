import Foundation
@testable import Snap_O
import Testing

struct ToolMetadataTests {
  @Test
  static func compatibilityStates() throws {
    func status(tools: [[String: Any]], errors: [[String: String]] = []) throws -> ToolCompatibility {
      let record: [String: Any] = [
        "version": 1, "pid": 42, "processIdentity": "boot:42:1", "androidUserId": 0,
        "app": ["name": "Demo", "packageName": "com.example.demo", "revision": "1", "inspectors": tools, "errors": errors]
      ]
      let manifest = try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
      var metadata = ToolMetadata()
      metadata.applyPackageMetadata(manifest, kind: .network)
      return ToolHTTPService.App(
        kind: .network, pid: 42, deviceID: "phone", deviceDisplayTitle: "Phone", socketName: "snapo_network_42", metadata: metadata
      ).compatibility
    }
    let descriptor: [String: Any] = ["id": "network", "name": "Network"]
    let missingFrontend = try status(tools: [descriptor])
    #expect(missingFrontend == .missingFrontend)
    let missingDescriptor = try status(tools: [])
    #expect(missingDescriptor == .missingDescriptor)
    let invalidDescriptor = try status(tools: [], errors: [["key": "snapo.inspector.network", "error": "Invalid XML"]])
    #expect(invalidDescriptor == .invalidDescriptor)
    let siblingError = try status(tools: [], errors: [["key": "snapo.inspector.tweaks", "error": "Invalid XML"]])
    #expect(siblingError == .missingDescriptor)
    for version in [0, 1, 2, 3, 4] {
      var value = descriptor
      value["frontend"] = ["assetPath": "frontend.zip", "hostApiVersion": version]
      let actual = try status(tools: [value])
      #expect(actual == (version == 1 ? .supported : .hostAPI(version: version)))
    }
    var pending = ToolHTTPService.App(
      kind: .network,
      pid: 42,
      deviceID: "phone",
      deviceDisplayTitle: "Phone",
      socketName: "snapo_network_42"
    )
    #expect(pending.compatibility == .unknown)
    pending.metadataReadFailed = true
    #expect(pending.compatibility == .metadataUnavailable && !pending.compatibility.isUnsupported)
  }

  @Test(arguments: [29, 30])
  static func metadataRetryBoundary(seconds: Int) {
    let now = ContinuousClock.now
    var app = ToolHTTPService.App(
      kind: .network, pid: 42, deviceID: "phone", deviceDisplayTitle: "Phone", socketName: "snapo_network_42"
    )
    #expect(app.needsMetadataRead(lastAttempt: nil, now: now))
    #expect(app.needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(seconds))) == (seconds >= 30))
    app.metadata.applyPackageMetadata(testManifest(pid: 42, kinds: [.network]), kind: .network)
    #expect(!app.needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(60))))
    app.awaitingMetadata = true
    #expect(app.needsMetadataRead(lastAttempt: nil, now: now))
    #expect(!app.needsMetadataRead(lastAttempt: now, now: now))
  }

  private static let legacy = LegacyPluginMetadata(
    packageName: "com.example.demo", name: "Demo", processName: "com.example.demo", protocolVersion: 1
  )

  @Test
  static func legacyMetadataDoesNotAuthorizeAManifest() throws {
    var metadata = ToolMetadata()
    let accepted = metadata.applyLegacyMetadata(legacy, kind: .network)
    #expect(accepted)
    #expect(metadata.process.name == "Demo" && metadata.process.packageName == "com.example.demo")
    #expect(metadata.process.verifiedIdentity == nil && metadata.process.tools.isEmpty)
    #expect(metadata.compatibility == .legacy(protocolVersion: 1))
    let connection = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
      ToolConnectionState(metadata: metadata.process)
    )) as? [String: Any])
    #expect(connection["manifest"] == nil)
  }

  @Test
  static func verifiedDescriptorSupersedesLegacyMetadata() throws {
    var metadata = ToolMetadata()
    metadata.applyLegacyMetadata(legacy, kind: .network)
    let accepted = try metadata.applyPackageMetadata(record(kinds: [.network]), kind: .network)
    #expect(accepted)
    let previous = metadata
    let acceptedLegacy = metadata.applyLegacyMetadata(legacy, kind: .network)
    #expect(!acceptedLegacy && metadata == previous)
    #expect(metadata.process.name == "Package label" && metadata.process.verifiedIdentity != nil)
    #expect(metadata.compatibility == .supported)
  }

  @Test
  static func legacyFallbackSurvivesOnlyTheSameVerifiedIdentity() throws {
    var metadata = ToolMetadata()
    try metadata.applyPackageMetadata(record(), kind: .network)
    let accepted = metadata.applyLegacyMetadata(legacy, kind: .network)
    #expect(accepted && metadata.process.name == "Package label")
    try metadata.applyPackageMetadata(record(kinds: [.tweaks]), kind: .network)
    #expect(metadata.compatibility == .legacy(protocolVersion: 1))
    try metadata.applyPackageMetadata(record(revision: "2"), kind: .network)
    #expect(metadata.compatibility == .missingDescriptor)
  }

  @Test(arguments: ["package", "process"])
  static func rejectsConflictingLegacyIdentity(field: String) throws {
    var metadata = ToolMetadata()
    try metadata.applyPackageMetadata(record(
      package: field == "package" ? "com.example.other" : "com.example.demo",
      processName: field == "process" ? "com.example.demo:other" : "com.example.demo"
    ), kind: .network)
    let previous = metadata
    let accepted = metadata.applyLegacyMetadata(legacy, kind: .network)
    #expect(!accepted && metadata == previous)
  }

  private static func record(
    package: String = "com.example.demo",
    processName: String = "com.example.demo",
    revision: String = "1",
    kinds: [ToolID] = []
  ) throws -> ToolProcessMetadata {
    let value: [String: Any] = [
      "version": 1, "pid": 42, "processIdentity": "boot:42:1", "androidUserId": 0, "processName": processName,
      "app": [
        "name": "Package label",
        "packageName": package,
        "revision": revision,
        "inspectors": kinds.map { kind in
          [
            "id": kind.rawValue,
            "name": kind.rawValue,
            "frontend": ["assetPath": "frontend.zip", "hostApiVersion": 1]
          ] as [String: Any]
        }
      ]
    ]
    return try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: value))
  }
}

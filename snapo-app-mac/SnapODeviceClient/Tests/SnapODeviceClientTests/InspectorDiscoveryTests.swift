import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("Inspector process discovery")
struct InspectorDiscoveryTests {
  @Test("shared inspector types preserve the web bridge wire format")
  func preservesBridgeEncoding() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try String(decoding: encoder.encode(InspectorKind.tweaks), as: UTF8.self) == "\"tweaks\"")
    let server = NetworkServerReference(deviceId: "device", socketName: "snapo_tweaks_42")
    #expect(try String(decoding: encoder.encode(server), as: UTF8.self)
      == "{\"deviceId\":\"device\",\"socketName\":\"snapo_tweaks_42\"}")
  }

  @Test("extracts only valid process IDs from both inspector sockets")
  func parsesProcessIDs() {
    #expect(InspectorKind.network.pid(inSocketName: "snapo_network_42") == 42)
    #expect(InspectorKind.tweaks.pid(inSocketName: "snapo_tweaks_42") == 42)
    for suffix in ["", "0", "-1", "+1", "42_extra", "999999999999999999999999"] {
      #expect(InspectorKind.network.pid(inSocketName: "snapo_network_\(suffix)") == nil)
      #expect(InspectorKind.tweaks.pid(inSocketName: "snapo_tweaks_\(suffix)") == nil)
    }
    #expect(InspectorKind.network.pid(inSocketName: "snapo_tweaks_42") == nil)
  }

  @Test("merges inspector sockets before any app info is available")
  func mergesWithoutMetadata() throws {
    let processes = InspectorDiscovery.processes(from: [endpoint(.tweaks), endpoint(.network)])
    let process = try #require(processes.first)

    #expect(processes.count == 1)
    #expect(process.id == "device:pid:42")
    #expect(process.name == "Process 42")
    #expect(process.inspectors.map(\.kind) == [.network, .tweaks])
  }

  @Test("keeps identity as better metadata arrives from either inspector")
  func improvesMetadata() throws {
    let initial = try #require(InspectorDiscovery.processes(from: [endpoint(.network)]).first)
    let network = endpoint(.network, metadata: InspectorAppMetadata(
      processName: "com.example.demo:worker",
      packageName: "com.example.demo",
      packageNameHint: "com.example.demo:worker",
      appIconBase64: "network-icon"
    ))
    let tweaks = endpoint(.tweaks, metadata: InspectorAppMetadata(
      appName: "Demo App",
      packageName: "com.example.demo"
    ))
    let loaded = try #require(InspectorDiscovery.processes(from: [tweaks, network]).first)

    #expect(loaded.id == initial.id)
    #expect(loaded.name == "Demo App")
    #expect(loaded.metadata.packageName == "com.example.demo")
    #expect(loaded.metadata.appIconBase64 == "network-icon")
    #expect(loaded.inspectors.map(\.reference.socketName) == ["snapo_network_42", "snapo_tweaks_42"])
  }

  @Test("does not merge different processes or devices sharing a package")
  func separatesProcesses() {
    let metadata = InspectorAppMetadata(packageName: "com.example.demo")
    let processes = InspectorDiscovery.processes(from: [
      endpoint(.network, metadata: metadata),
      endpoint(.tweaks, pid: 43, metadata: metadata),
      endpoint(.tweaks, device: "other-device", metadata: metadata)
    ])
    #expect(Set(processes.map(\.id)) == ["device:pid:42", "device:pid:43", "other-device:pid:42"])
  }

  @Test("ignores empty metadata and prefers confirmed package names to hints")
  func usesBestNonemptyMetadata() throws {
    let network = endpoint(.network, metadata: InspectorAppMetadata(
      processName: " \n", packageNameHint: "com.example.demo:worker", appIconBase64: ""
    ))
    let tweaks = endpoint(.tweaks, metadata: InspectorAppMetadata(
      appName: " ", packageName: "com.example.demo", appIconBase64: "tweaks-icon"
    ))
    let process = try #require(InspectorDiscovery.processes(from: [network, tweaks]).first)
    #expect(process.name == "com.example.demo")
    #expect(process.metadata.appIconBase64 == "tweaks-icon")
  }

  @Test("unknown socket identities never merge by a display name")
  func keepsUnknownSocketsSeparate() {
    let endpoints = ["legacy-one", "legacy-two"].map {
      InspectorEndpoint(
        kind: .network,
        reference: NetworkServerReference(deviceId: "device", socketName: $0),
        deviceDisplayTitle: "Device",
        metadata: InspectorAppMetadata(appName: "Same name")
      )
    }
    #expect(InspectorDiscovery.processes(from: endpoints).map(\.id) == [
      "device:socket:legacy-one", "device:socket:legacy-two"
    ])
  }

  private func endpoint(
    _ kind: InspectorKind,
    device: String = "device",
    pid: Int = 42,
    metadata: InspectorAppMetadata = InspectorAppMetadata()
  ) -> InspectorEndpoint {
    InspectorEndpoint(
      kind: kind,
      reference: NetworkServerReference(deviceId: device, socketName: "\(kind.socketPrefix)\(pid)"),
      deviceDisplayTitle: "Device",
      metadata: metadata
    )
  }
}

import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("Inspector process discovery")
struct InspectorDiscoveryTests {
  private let definitions = ["network", "tweaks", "sample"].map {
    InspectorSocketDefinition(id: InspectorID(rawValue: $0), socketPrefix: "snapo_\($0)_")
  }

  @Test("discovers both inspector kinds from one socket snapshot")
  func parsesSharedSnapshot() {
    let output = """
    1: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42
    2: 00000002 00000000 00010000 0001 01 101 @snapo_network_42
    3: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42
    4: 00000002 00000000 00010000 0001 01 101 @snapo_network_invalid
    5: 00000002 00000000 00010000 0001 01 101 @snapo_unknown_42
    6: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_0
    """
    let sockets = InspectorDiscovery.sockets(inProcNetUnix: output, deviceID: "phone", definitions: definitions)
    #expect(sockets.map(\.kind) == [.network, .tweaks])
    #expect(sockets.map(\.reference.deviceId) == ["phone", "phone"])
    #expect(sockets.map(\.reference.socketName) == ["snapo_network_42", "snapo_tweaks_42"])
  }

  @Test("shared inspector types preserve the web bridge wire format")
  func preservesBridgeEncoding() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try String(bytes: encoder.encode(InspectorID.tweaks), encoding: .utf8) == "\"tweaks\"")
    let server = InspectorServerReference(deviceId: "device", socketName: "snapo_tweaks_42")
    #expect(try String(bytes: encoder.encode(server), encoding: .utf8)
      == "{\"deviceId\":\"device\",\"socketName\":\"snapo_tweaks_42\"}")
  }

  @Test("client connections never replace the listening socket identity")
  func ignoresClientSockets() throws {
    let listener = "1: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42"
    for inode in ["0", "202", "303"] {
      let clients = """
      2: 00000002 00000000 00000000 0001 02 0 @snapo_tweaks_42
      3: 00000002 00000000 00000000 0001 03 \(inode) @snapo_tweaks_42
      4: 00000002 00000000 00000000 0001 03 404 @snapo_network_43
      """
      for snapshot in [clients + "\n" + listener, listener + "\n" + clients] {
        let sockets = InspectorDiscovery.sockets(inProcNetUnix: snapshot, deviceID: "phone", definitions: definitions)
        #expect(sockets.count == 1)
        #expect(try #require(sockets.first).inode == "101")
      }
      #expect(InspectorDiscovery.sockets(inProcNetUnix: clients, deviceID: "phone", definitions: definitions).isEmpty)
    }
  }

  @Test("discovery includes process names before manifest resources load")
  func includesInitialProcessNames() throws {
    let output = """
    1: 00000002 00000000 00010000 0001 01 101 @snapo_network_42
    2: 00000002 00000000 00010000 0001 01 102 @snapo_tweaks_42
    3: 00000002 00000000 00010000 0001 01 103 @snapo_network_43

    ---snapo-processes---
      PID NAME
       42 com.example.demo:worker
       44 com.example.other
    """
    let sockets = InspectorDiscovery.sockets(inProcNetUnix: output, deviceID: "phone", definitions: definitions)
    #expect(sockets.filter { $0.pid == 42 }.allSatisfy { $0.processName == "com.example.demo:worker" })
    #expect(sockets.first { $0.pid == 43 }?.processName == nil)
    #expect(sockets.map(\.inode) == ["101", "103", "102"])
    let socket = try #require(sockets.first)
    let process = try #require(InspectorDiscovery.processes(from: [
      endpoint(socket.kind, metadata: InspectorAppMetadata(processName: socket.processName))
    ]).first)
    #expect(process.name == "com.example.demo:worker")
  }

  @Test("process name lookup supports legacy ps columns and tolerates unavailable names")
  func parsesLegacyProcessNames() {
    #expect(DeviceDiscovery.processNames(inProcessList: """
    USER PID PPID VSIZE RSS WCHAN PC NAME
    u0_a42 42 1 1000 100 0 0 com.example.demo
    u0_a43 invalid 1 1000 100 0 0 com.example.invalid
    incomplete
    """) == [42: "com.example.demo"])
    #expect(DeviceDiscovery.processNames(inProcessList: "ps: permission denied").isEmpty)
  }

  @Test("refreshes one reader file after replacement or deletion")
  func refreshesManifestReader() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "snapo-reader-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appending(path: "snapo-discovery.jar")
    let helper = Data("fixture reader".utf8)
    let command = try InspectorManifestReader.command(helper: helper, socketNames: ["snapo_network_42"])
      .replacingOccurrences(of: "/data/local/tmp", with: directory.path)
    // Capture the file the runtime would open without requiring Android in the unit test.
    let script = "app_process() { cat \"$CLASSPATH\"; };\n" + command
    for attempt in 0 ..< 3 {
      if attempt == 1 {
        try FileManager.default.removeItem(at: destination)
        try Data("different reader".utf8).write(to: destination)
      } else if attempt == 2 {
        try FileManager.default.removeItem(at: destination)
      }
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-c", script]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      let bytes = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
      #expect(bytes == helper)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["snapo-discovery.jar"])
    }
  }

  @Test("successful metadata requires process identity, but error records do not")
  func requiresProcessIdentity() throws {
    let app: [String: Any] = ["name": "Example", "packageName": "com.example", "revision": "1", "inspectors": []]
    for identity: Any in [NSNull(), "", " ", 42] {
      let data = try JSONSerialization.data(withJSONObject: [
        "version": 1, "pid": 42, "app": app, "processIdentity": identity
      ])
      #expect(throws: (any Error).self) { try InspectorManifestReader.decode(data) }
    }
    let success = try JSONSerialization.data(withJSONObject: [
      "version": 1, "pid": 42, "app": app, "processIdentity": "boot:42:1"
    ])
    #expect(try InspectorManifestReader.decode(success).first?.processIdentity == "boot:42:1")
    let failure = Data(#"{"version":1,"pid":42,"error":"process exited"}"#.utf8)
    #expect(try InspectorManifestReader.decode(failure).first?.error == "process exited")
  }

  @Test("extracts only valid process IDs from both inspector sockets")
  func parsesProcessIDs() {
    #expect(definitions[0].pid(inSocketName: "snapo_network_42") == 42)
    #expect(definitions[1].pid(inSocketName: "snapo_tweaks_42") == 42)
    for suffix in ["", "0", "-1", "+1", "42_extra", "999999999999999999999999"] {
      #expect(definitions[0].pid(inSocketName: "snapo_network_\(suffix)") == nil)
      #expect(definitions[1].pid(inSocketName: "snapo_tweaks_\(suffix)") == nil)
    }
    #expect(definitions[0].pid(inSocketName: "snapo_tweaks_42") == nil)
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
      packageName: "com.example.demo",
      androidUserID: 10
    ))
    let loaded = try #require(InspectorDiscovery.processes(from: [tweaks, network]).first)

    #expect(loaded.id == initial.id)
    #expect(loaded.name == "Demo App")
    #expect(loaded.metadata.packageName == "com.example.demo")
    #expect(loaded.metadata.androidUserID == 10)
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
    let legacy = try #require(InspectorDiscovery.processes(from: [network]).first)
    #expect(legacy.metadata.packageName == nil)
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
        reference: InspectorServerReference(deviceId: "device", socketName: $0),
        deviceDisplayTitle: "Device",
        metadata: InspectorAppMetadata(appName: "Same name")
      )
    }
    #expect(InspectorDiscovery.processes(from: endpoints).map(\.id) == [
      "device:socket:legacy-one", "device:socket:legacy-two"
    ])
  }

  private func endpoint(
    _ kind: InspectorID,
    device: String = "device",
    pid: Int = 42,
    metadata: InspectorAppMetadata = InspectorAppMetadata()
  ) -> InspectorEndpoint {
    InspectorEndpoint(
      kind: kind,
      reference: InspectorServerReference(deviceId: device, socketName: "snapo_\(kind.rawValue)_\(pid)"),
      deviceDisplayTitle: "Device",
      pid: pid,
      metadata: metadata
    )
  }
}

private extension InspectorID {
  static let network = Self(rawValue: "network")
  static let tweaks = Self(rawValue: "tweaks")
}

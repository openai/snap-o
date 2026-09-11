import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("Inspector process discovery")
struct InspectorDiscoveryTests {
  @Test("discovers app-provided inspector kinds from one socket snapshot")
  func parsesSharedSnapshot() {
    let output = """
    1: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42
    2: 00000002 00000000 00010000 0001 01 101 @snapo_network_42
    3: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42
    4: 00000002 00000000 00010000 0001 01 101 @snapo_network_invalid
    5: 00000002 00000000 00010000 0001 01 101 @snapo_unknown_42
    6: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_0
    """
    let sockets = InspectorDiscovery.sockets(inProcNetUnix: output, deviceID: "phone")
    #expect(sockets.map(\.kind) == [.network, .tweaks, InspectorID(rawValue: "unknown")])
    #expect(sockets.map(\.reference.deviceId) == ["phone", "phone", "phone"])
    #expect(sockets.map(\.reference.socketName) == ["snapo_network_42", "snapo_tweaks_42", "snapo_unknown_42"])
  }

  @Test("socket names follow the standard inspector ID and PID format")
  func validatesSocketNames() {
    for id in ["sample", "com.example.custom-inspector", "a" + String(repeating: "b", count: 99)] {
      let output = "1: 00000002 00000000 00010000 0001 01 101 @snapo_\(id)_42"
      let sockets = InspectorDiscovery.sockets(inProcNetUnix: output, deviceID: "phone")
      #expect(sockets.map(\.kind.rawValue) == [id])
      #expect(sockets.map(\.pid) == [42])
    }
    for name in [
      "custom_sample_42", "snapo__42", "snapo_Sample_42", "snapo_a_b_42", "snapo_../sample_42",
      "snapo_sample_", "snapo_sample_0", "snapo_sample_01", "snapo_sample_-1", "snapo_sample_+1",
      "snapo_sample_42extra", "snapo_sample_42_extra", "snapo_sample_999999999999999999999999",
      "snapo_sample_10000000000", "snapo_sample_４２", "snapo_" + String(repeating: "a", count: 101) + "_42"
    ] {
      let output = "1: 00000002 00000000 00010000 0001 01 101 @\(name)"
      #expect(InspectorDiscovery.sockets(inProcNetUnix: output, deviceID: "phone").isEmpty)
    }
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
        let sockets = InspectorDiscovery.sockets(inProcNetUnix: snapshot, deviceID: "phone")
        #expect(sockets.count == 1)
        #expect(try #require(sockets.first).inode == "101")
      }
      #expect(InspectorDiscovery.sockets(inProcNetUnix: clients, deviceID: "phone").isEmpty)
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
    let sockets = InspectorDiscovery.sockets(inProcNetUnix: output, deviceID: "phone")
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

  @Test("removes the reader after successful and failed invocations")
  func cleansUpManifestReader() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "snapo-reader-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = Data("fixture reader".utf8)
    let command = try InspectorManifestReader.command(helper: helper, socketNames: ["snapo_network_42"])
      .replacingOccurrences(of: "/data/local/tmp", with: directory.path)
    // Capture the file the runtime would open without requiring Android in the unit test.
    for status: Int32 in [0, 7] {
      let script = "app_process() { cat \"$CLASSPATH\"; return \(status); };\n" + command
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-c", script]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      let bytes = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == status)
      #expect(bytes == helper)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }

  @Test("overlapping readers execute their own helper even after another reader exits")
  func isolatesManifestReaders() throws {
    struct Reader {
      let process: Process
      let input: Pipe
      let output: Pipe
      let helper: Data
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "snapo-readers-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var readers: [Reader] = []
    defer {
      for reader in readers where reader.process.isRunning {
        reader.process.terminate()
        reader.process.waitUntilExit()
      }
    }
    for name in ["first reader", "second reader"] {
      let helper = Data(name.utf8)
      let command = try InspectorManifestReader.command(helper: helper, socketNames: ["snapo_network_42"])
        .replacingOccurrences(of: "/data/local/tmp", with: directory.path)
      // Hold both runtimes after upload. The timeout bounds a failed test.
      let script = "app_process() { printf 'ready\\n'; read -r -t 5 proceed || return 1; cat \"$CLASSPATH\"; };\n" + command
      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-c", script]
      process.standardInput = input
      process.standardOutput = output
      try process.run()
      readers.append(Reader(process: process, input: input, output: output, helper: helper))
      try #require(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
    }
    for reader in readers.reversed() {
      try reader.input.fileHandleForWriting.write(contentsOf: Data("continue\n".utf8))
      let bytes = reader.output.fileHandleForReading.readDataToEndOfFile()
      reader.process.waitUntilExit()
      #expect(reader.process.terminationStatus == 0)
      #expect(bytes == reader.helper)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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

extension InspectorDiscoveryTests {
  @Test("legacy metadata accepts only recognized protocols and matching process identity")
  func legacyMetadataEvidence() throws {
    let network = Data(
      #"{"method":"SnapO.appInfo","params":{"protocolVersion":1,"packageName":"com.example.demo","processName":"com.example.demo","pid":42}}"#
        .utf8
    )
    #expect(try LegacyInspectorReader.decode(network, kind: .network, pid: 42, http: false)?.protocolVersion == 1)
    #expect(try LegacyInspectorReader.decode(network, kind: .network, pid: 43, http: false) == nil)
    let http = Data(#"{"protocolVersion":2,"packageName":"com.example.demo","processName":"com.example.demo","pid":42}"#.utf8)
    #expect(try LegacyInspectorReader.decode(http, kind: .network, pid: 42, http: true)?.protocolVersion == 2)
    for version in [5, 6, 7, 100] {
      let tweaks = Data("{\"protocolVersion\":\(version),\"packageName\":\"com.example.demo\",\"name\":\"Demo\"}".utf8)
      #expect(try (LegacyInspectorReader.decode(tweaks, kind: .tweaks, pid: 42, http: true) != nil) == (version < 7))
    }
    #expect(LegacyInspectorReader.requests(kind: InspectorID(rawValue: "custom")).isEmpty)
    #expect(LegacyInspectorReader.requests(kind: .network).first == "HelloSnapO\n")
    #expect(LegacyInspectorReader.requests(kind: .tweaks).allSatisfy { $0.hasPrefix("GET ") })
  }

  @Test("legacy metadata responses are bounded and reject redirects and malformed framing")
  func legacyMetadataFraming() throws {
    #expect(try LegacyInspectorReader.payload(Data("{}\nextra".utf8), http: false) == Data("{}".utf8))
    #expect(try LegacyInspectorReader.payload(Data("{".utf8), http: false) == nil)
    let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
    #expect(try LegacyInspectorReader.payload(Data(response.utf8), http: true) == Data("{}".utf8))
    #expect(try LegacyInspectorReader.payload(Data(response.dropLast().utf8), http: true) == nil)
    #expect(try LegacyInspectorReader.payload(Data("HTTP/1.0 200 OK\r\n\r\n{}".utf8), http: true, ended: true) == Data("{}".utf8))
    for invalid in [
      "HTTP/1.1 302 Found\r\nLocation: https://example.com\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      String(repeating: "x", count: 8193)
    ] {
      #expect(throws: (any Error).self) { try LegacyInspectorReader.payload(Data(invalid.utf8), http: true) }
    }
    #expect(throws: (any Error).self) {
      try LegacyInspectorReader.payload(Data(repeating: 120, count: LegacyInspectorReader.maximumBytes + 1), http: false)
    }
  }
}

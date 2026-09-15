import Darwin
import Foundation

public struct ToolFrontendBundle: Sendable {}

public final class ADBSocketConnection: @unchecked Sendable {
  func takeSocketDescriptor() throws -> Int32 {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EIO) }
    let peer = descriptors[1]
    var noSignal: Int32 = 1
    _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    DispatchQueue.global().async {
      defer { Darwin.close(peer) }
      var request = [UInt8](repeating: 0, count: 16 * 1024)
      guard Darwin.recv(peer, &request, request.count, 0) > 0 else { return }
      let response = Array("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)
      _ = response.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
    }
    return descriptors[0]
  }

  public func close() {}
}

public final class ADBClient: @unchecked Sendable {
  public enum MetadataFailure: Sendable {
    case request, record
  }

  private let lock = NSLock()
  private var toolConnections = 0
  private var failedToolConnections = 0
  private var frozen = true
  private var networkDisconnected = false
  private var propertiesRecovered = false
  private var metadataAvailable = false
  private var metadataRequests: [[Int]] = []
  private var metadataFailure: MetadataFailure?
  private var legacyKinds: Set<ToolID> = []
  private var legacyRequests = 0
  private var legacyBlocked = false
  private var legacyCancellations = 0

  public func setMetadataFailure(_ failure: MetadataFailure?) {
    lock.withLock { metadataFailure = failure }
  }

  public func setLegacyBlocked(_ blocked: Bool) {
    lock.withLock { legacyBlocked = blocked }
  }

  public var legacyCancellationCount: Int {
    lock.withLock { legacyCancellations }
  }

  public func setLegacyKinds(_ kinds: Set<ToolID>) {
    lock.withLock { legacyKinds = kinds }
  }

  public var legacyRequestCount: Int {
    lock.withLock { legacyRequests }
  }

  private var socketDevices: [String] = []
  private var socketsByDevice: [String: [String]] = [:]
  private var socketGeneration = 0
  private let trackedDevices = AsyncThrowingStream<String, Error>.makeStream()
  public init() {}
  public var toolConnectionCount: Int {
    lock.withLock { toolConnections }
  }

  public var failedToolConnectionCount: Int {
    lock.withLock { failedToolConnections }
  }

  public func unfreeze() {
    lock.withLock { frozen = false }
  }

  public func disconnectNetwork() {
    lock.withLock { networkDisconnected = true }
  }

  public func openLocalAbstract(deviceID: String, abstractSocket: String) async throws -> ADBSocketConnection {
    lock.withLock { toolConnections += 1 }
    if deviceID == "direct-failure" { throw ADBError.requestTimedOut("Test timeout") }
    let shouldFail = lock.withLock {
      let failed = deviceID == "frozen" && (frozen || abstractSocket.contains("network") && networkDisconnected)
      if failed { failedToolConnections += 1 }
      return failed
    }
    if shouldFail { throw ADBError.requestTimedOut("Test timeout") }
    return ADBSocketConnection()
  }

  public var scannedDeviceIDs: [String] {
    lock.withLock { socketDevices }
  }

  public func recoverProperties() {
    lock.withLock { propertiesRecovered = true }
  }

  public func setMetadataAvailable(_ available: Bool) {
    lock.withLock { metadataAvailable = available }
  }

  public var metadataProcessRequests: [[Int]] {
    lock.withLock { metadataRequests }
  }

  public func pluginMetadata(deviceID: String, processIDs: [Int], helperURL: URL) async throws -> [ToolProcessMetadata] {
    precondition(!processIDs.isEmpty && processIDs.count <= 64)
    lock.withLock { metadataRequests.append(processIDs) }
    while !lock.withLock({ metadataAvailable }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let failure = lock.withLock { metadataFailure }
    if failure == .request { throw ADBError.requestTimedOut("Test metadata timeout") }
    let pids = Set(processIDs)
    if failure == .record {
      return try pids.map { pid in
        try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: [
          "version": 1, "pid": pid, "error": "Test metadata failure"
        ]))
      }
    }
    let tools: [[String: Any]] = [
      ["id": "network", "name": "Network", "frontend": ["assetPath": "network.zip", "hostApiVersion": 1]],
      ["id": "tweaks", "name": "Tweaks", "frontend": ["assetPath": "tweaks.zip", "hostApiVersion": 1]],
      ["id": "sample", "name": "Sample", "frontend": ["assetPath": "sample.zip", "hostApiVersion": 1]]
    ].filter { descriptor in
      !lock.withLock { legacyKinds.contains(ToolID(rawValue: descriptor["id"] as! String)) }
    }
    return try pids.map { pid in
      let record: [String: Any] = [
        "version": 1, "pid": pid, "processName": "com.example.demo", "androidUserId": 0,
        "processIdentity": "boot:\(pid):1",
        "app": [
          "name": "Demo", "packageName": "com.example.demo", "revision": "1",
          "iconBase64": "icon-\(deviceID)",
          "inspectors": tools
        ]
      ]
      return try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
    }
  }

  public func legacyPluginMetadata(
    reference: ToolServerReference,
    kind: ToolID,
    pid: Int
  ) async throws -> LegacyPluginMetadata? {
    lock.withLock { legacyRequests += 1 }
    do {
      while lock.withLock({ legacyBlocked }) {
        try await Task.sleep(for: .milliseconds(10))
      }
      try Task.checkCancellation()
    } catch {
      if Task.isCancelled { lock.withLock { legacyCancellations += 1 } }
      throw error
    }
    return lock.withLock {
      legacyKinds.contains(kind) ? LegacyPluginMetadata(
        packageName: "com.example.demo", name: "Demo", processName: "com.example.demo", protocolVersion: 1
      ) : nil
    }
  }

  public func pluginFrontend(
    deviceID: String, socketName: String, identity: ToolProcessIdentity,
    tool: ToolDescriptor, helperURL: URL
  ) async throws -> ToolFrontendBundle {
    ToolFrontendBundle()
  }

  public func emitDevices(_ payload: String) {
    trackedDevices.continuation.yield(payload)
  }

  public func trackDevices() async throws -> (handle: TrackDevicesHandle, stream: AsyncThrowingStream<String, Error>) {
    (TrackDevicesHandle { self.trackedDevices.continuation.finish() }, trackedDevices.stream)
  }

  public func getProperties(deviceID: String, prefix: String?) async throws -> [String: String] {
    if deviceID == "stalled", !lock.withLock({ propertiesRecovered }) { throw ADBError.requestTimedOut("Test timeout") }
    return ["ro.product.model": deviceID, "ro.build.version.release": "Test"]
  }

  public func openApp(deviceID: String, packageName: String, androidUserID: Int) async throws {}

  public func setSocketNames(_ names: [String], deviceID: String) {
    lock.withLock { socketsByDevice[deviceID] = names }
  }

  public func replaceListeners() {
    lock.withLock { socketGeneration += 100 }
  }

  public func listUnixSockets(deviceID: String) async throws -> String {
    let names = lock.withLock {
      socketDevices.append(deviceID)
      return socketsByDevice[deviceID] ?? ["snapo_network_42", "snapo_tweaks_42"]
    }
    let clientInode = lock.withLock { socketDevices.count + 1000 }
    let listenerInode = lock.withLock { socketGeneration + 100 }
    return names.enumerated().map { index, name in
      """
      0: 00000002 00000000 00000000 0001 03 \(clientInode) @\(name)
      1: 00000002 00000000 00010000 0001 01 \(index + listenerInode) @\(name)
      """
    }.joined(separator: "\n")
  }

  public func runDiscoveryShellString(deviceID: String, command: String) async throws -> String {
    if command == ToolDiscovery.snapshotCommand {
      return try await listUnixSockets(deviceID: deviceID) + "\n\n---snapo-processes---\nPID NAME\n42 com.example.demo\n43 com.example.demo:worker\n"
    }
    return command.contains("cmdline") ? "com.example.demo" : "Uid: 10000"
  }
}

public struct TrackDevicesHandle: Sendable {
  let onCancel: @Sendable () -> Void
  public func cancel() {
    onCancel()
  }
}

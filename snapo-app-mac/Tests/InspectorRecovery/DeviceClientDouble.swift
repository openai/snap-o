import Foundation

public struct ADBForwardHandle: Sendable {
  public let port: UInt16
}

public struct InspectorFrontendBundle: Sendable {}

public final class ADBClient: @unchecked Sendable {
  public enum MetadataFailure: Sendable {
    case request, record
  }

  private let lock = NSLock()
  private var forwards = 0
  private var removedForwards: [UInt16] = []
  private var propertiesRecovered = false
  private var metadataAvailable = false
  private var metadataRequests: [[String]] = []
  private var metadataFailure: MetadataFailure?
  private var legacyKinds: Set<InspectorID> = []
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

  public func setLegacyKinds(_ kinds: Set<InspectorID>) {
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
  public var removedPorts: [UInt16] {
    lock.withLock { removedForwards }
  }

  public var forwardCount: Int {
    lock.withLock { forwards }
  }

  public func forwardLocalAbstract(deviceID: String, abstractSocket: String) async throws -> ADBForwardHandle {
    lock.withLock { forwards += 1 }
    if deviceID == "forward-failure" { throw ADBError.requestTimedOut("Test timeout") }
    return ADBForwardHandle(port: deviceID == "frozen" ? (abstractSocket.contains("network") ? 12344 : 12345) : 12346)
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

  public var metadataSocketRequests: [[String]] {
    lock.withLock { metadataRequests }
  }

  public func inspectorMetadata(deviceID: String, socketNames: [String], helperURL: URL) async throws -> [InspectorProcessMetadata] {
    lock.withLock { metadataRequests.append(socketNames) }
    while !lock.withLock({ metadataAvailable }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let failure = lock.withLock { metadataFailure }
    if failure == .request { throw ADBError.requestTimedOut("Test metadata timeout") }
    let pids = Set(socketNames.compactMap { Int($0.split(separator: "_").last ?? "") })
    if failure == .record {
      return try pids.map { pid in
        try JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: [
          "version": 1, "pid": pid, "error": "Test metadata failure"
        ]))
      }
    }
    let inspectors: [[String: Any]] = [
      ["id": "network", "name": "Network", "protocolVersion": 3, "frontend": ["assetPath": "network.zip", "hostApiVersion": 1]],
      ["id": "tweaks", "name": "Tweaks", "protocolVersion": 7, "frontend": ["assetPath": "tweaks.zip", "hostApiVersion": 1]]
    ].filter { descriptor in
      !lock.withLock { legacyKinds.contains(InspectorID(rawValue: descriptor["id"] as! String)) }
        && socketNames.contains { $0.hasPrefix("snapo_\(descriptor["id"]!)_") }
    }
    return try pids.map { pid in
      let record: [String: Any] = [
        "version": 1, "pid": pid, "processName": "com.example.demo", "androidUserId": 0,
        "processIdentity": "boot:\(pid):1",
        "app": [
          "name": "Demo", "packageName": "com.example.demo", "revision": "1",
          "iconBase64": "icon-\(deviceID)",
          "inspectors": inspectors
        ]
      ]
      return try JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
    }
  }

  public func legacyInspectorMetadata(
    reference: InspectorServerReference,
    kind: InspectorID,
    pid: Int
  ) async throws -> LegacyInspectorMetadata? {
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
      legacyKinds.contains(kind) ? LegacyInspectorMetadata(
        packageName: "com.example.demo", name: "Demo", processName: "com.example.demo", protocolVersion: 1
      ) : nil
    }
  }

  public func inspectorFrontend(
    deviceID: String, socketName: String, identity: InspectorProcessIdentity,
    inspector: InspectorDescriptor, helperURL: URL
  ) async throws -> InspectorFrontendBundle {
    InspectorFrontendBundle()
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

  public func removeForward(_ handle: ADBForwardHandle) async {
    precondition(!Task.isCancelled)
    lock.withLock { removedForwards.append(handle.port) }
  }

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
    if command == InspectorDiscovery.snapshotCommand {
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

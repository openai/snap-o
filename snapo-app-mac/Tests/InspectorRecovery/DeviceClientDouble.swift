import Foundation

public struct ADBForwardHandle: Sendable {
  public let port: UInt16
}

public final class ADBClient: @unchecked Sendable {
  private let lock = NSLock()
  private var forwards = 0
  private var propertiesRecovered = false
  private var metadataAvailable = false
  private var socketDevices: [String] = []
  private var socketsByDevice: [String: [String]] = [:]
  private var socketGeneration = 0
  private let trackedDevices = AsyncThrowingStream<String, Error>.makeStream()
  public init() {}
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

  public func inspectorMetadata(deviceID: String, socketNames: [String], helperURL: URL) async throws -> [InspectorProcessMetadata] {
    while !lock.withLock({ metadataAvailable }) { try await Task.sleep(for: .milliseconds(10)) }
    let pids = Set(socketNames.compactMap { Int($0.split(separator: "_").last ?? "") })
    return try pids.map { pid in
      let record: [String: Any] = [
        "version": 1, "pid": pid, "processName": "com.example.demo", "androidUserId": 0,
        "processIdentity": "boot:\(pid):1",
        "app": [
          "name": "Demo", "packageName": "com.example.demo", "revision": "1",
          "iconBase64": "icon-\(deviceID)",
          "inspectors": [
            ["id": "network", "name": "Network", "protocolVersion": 3],
            ["id": "tweaks", "name": "Tweaks", "protocolVersion": 7]
          ]
        ]
      ]
      return try JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
    }
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

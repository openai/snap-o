import Foundation
import Network
import SnapODeviceClient

actor ADBService {
  let client = ADBClient()
  func exec() -> ADBClient {
    client
  }
}

private final class InspectorHTTP: @unchecked Sendable {
  static let state = State()

  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var frozenRequests = 0
    private var frozen = true
    private var networkDisconnected = false
    var count: Int {
      lock.withLock { frozenRequests }
    }

    func unfreeze() {
      lock.withLock { frozen = false }
    }

    func disconnectNetwork() {
      lock.withLock { networkDisconnected = true }
    }

    func shouldFail(port: Int?) -> Bool {
      lock.withLock {
        guard port == 12345 || port == 12344 else { return false }
        frozenRequests += 1
        return frozen || (port == 12344 && networkDisconnected)
      }
    }
  }

  private var listeners: [NWListener] = []
  private let lock = NSLock()
  private var sockets: [NWConnection] = []

  func start() async throws {
    for port: UInt16 in [12344, 12345, 12346] {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { connection in
        self.lock.withLock { self.sockets.append(connection) }
        connection.start(queue: .global())
        self.read(connection, port: port)
      }
      listeners.append(listener)
      try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready: ready.resume()
          case .failed(let error): ready.resume(throwing: error)
          default: break
          }
        }
        listener.start(queue: .global())
      }
    }
  }

  func stop() {
    listeners.forEach { $0.cancel() }
    lock.withLock { sockets.forEach { $0.cancel() } }
  }

  private func read(_ connection: NWConnection, port: UInt16, previous: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
      guard let data, !data.isEmpty else { return }
      let request = previous + data
      guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
        self.read(connection, port: port, previous: request)
        return
      }
      if Self.state.shouldFail(port: Int(port)) { return }
      let icon = String(decoding: request, as: UTF8.self).contains("/.snap-o/appicon ")
      let status = icon ? "404 Not Found" : "200 OK"
      let body = #"{"name":"Demo","packageName":"com.example.demo","protocolVersion":2}"#
      let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}

enum SnapOLog {
  static let tracker = 0
}

@main
@MainActor
struct InspectorRecoveryTests {
  static func main() async throws {
    let http = InspectorHTTP()
    try await http.start()
    defer { http.stop() }
    let adbService = ADBService()
    let adb = await adbService.exec()
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    let payload = "frozen device transport_id:1\nhealthy device transport_id:2\nstalled device transport_id:3"
    adb.emitDevices(payload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy"] }
    let service = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    let suite = "SnapOHostRecoveryTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    preferences.set(#"{"apps":[]}"#, forKey: "inspectorPreferences")
    defer { preferences.removePersistentDomain(forName: suite) }
    let host = AppInspectorModel(
      preferences: preferences,
      discover: { await service.discoverInspectors() },
      openApp: { try await service.openApp($0) }
    )
    host.start()
    try await eventually {
      let apps = host.snapshot.state.apps
      return apps.count == 1 && apps.first?.deviceId == "healthy" && apps.first?.inspectors.count == 2
    }
    host.selectApp(host.snapshot.state.apps[0])
    precondition(host.snapshot.state.selection?.server.deviceId == "healthy")
    host.stop()
    print("Native discovery publishes and selects healthy apps beside stalled devices")
    let frozen = NetworkServerReference(deviceId: "frozen", socketName: "snapo_tweaks_42")
    let healthy = NetworkServerReference(deviceId: "healthy", socketName: "snapo_tweaks_42")
    _ = await service.discoverInspectors().apps
    try await eventually {
      let apps = await service.discoverInspectors().apps
      return InspectorHTTP.state.count == 2 && apps.count == 1 && apps.first?.inspectors.count == 2
    }
    let count = adb.forwardCount
    for _ in 0 ..< 50 {
      _ = await service.discoverInspectors().apps
      do {
        _ = try await service.inspectorEndpoint(for: frozen)
        fatalError("Frozen inspector should remain disconnected during cooldown")
      } catch InspectorError.serverNotConnected {}
    }
    precondition(adb.forwardCount == count)
    precondition(InspectorHTTP.state.count == 2)
    precondition(!adb.scannedDeviceIDs.contains("stalled"))
    print("A device with failed properties is excluded from app discovery")
    _ = try await service.inspectorEndpoint(for: healthy)
    print("Both inspector kinds suppress repeated failed connections while healthy inspectors remain usable")

    InspectorHTTP.state.unfreeze()
    try await Task.sleep(for: .milliseconds(3200))
    try await eventually { await service.discoverInspectors().apps.count == 2 }
    _ = try await service.inspectorEndpoint(for: frozen)
    precondition(adb.forwardCount == count + 2)
    print("Both inspector kinds reconnect automatically after cooldown")

    InspectorHTTP.state.disconnectNetwork()
    try await eventually {
      let apps = await service.discoverInspectors().apps
      return apps.first(where: { $0.deviceId == "frozen" })?.inspectors.map(\.kind) == [.tweaks]
    }
    let disconnectedCount = adb.forwardCount
    for _ in 0 ..< 50 {
      _ = await service.discoverInspectors().apps
    }
    precondition(adb.forwardCount == disconnectedCount)
    _ = try await service.inspectorEndpoint(for: frozen)
    print("A lost network connection enters cooldown without delaying tweaks in the same process")
    await service.stop()

    let restarted = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    try await eventually { await restarted.discoverInspectors().apps.count == 2 }
    _ = try await restarted.inspectorEndpoint(for: frozen)
    await restarted.stop()
    print("A new service instance can reconnect immediately")

    adb.recoverProperties()
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy", "stalled"] }
    let recovered = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    _ = await recovered.discoverInspectors().apps
    precondition(adb.scannedDeviceIDs.contains("stalled"))
    await recovered.stop()
    let failingPayload = "forward-failure device transport_id:4"
    adb.emitDevices(failingPayload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["forward-failure"] }
    let forwardFailure = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    let beforeForwardFailure = adb.forwardCount
    for _ in 0 ..< 50 {
      _ = await forwardFailure.discoverInspectors().apps
    }
    precondition(adb.forwardCount == beforeForwardFailure + 2)
    await forwardFailure.stop()
    print("Port forwarding failures enter the same cooldown as failed inspector requests")
    await tracker.stopTracking()
    print("Property failures recover without another device tracking event")
  }

  static func eventually(line: Int = #line, _ condition: () async -> Bool) async throws {
    for _ in 0 ..< 500 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    fatalError("Condition at line \(line) did not become true")
  }
}

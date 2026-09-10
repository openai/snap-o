import Foundation
import SnapODeviceClient

actor ADBService {
  let client = ADBClient()
  func exec() -> ADBClient {
    client
  }
}

private final class InspectorHTTP: URLProtocol, @unchecked Sendable {
  static let state = State()

  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var frozenRequests = 0
    private var frozen = true
    var count: Int {
      lock.withLock { frozenRequests }
    }

    func unfreeze() {
      lock.withLock { frozen = false }
    }

    func shouldFail(port: Int?) -> Bool {
      lock.withLock {
        guard port == 12345 else { return false }
        frozenRequests += 1
        return frozen
      }
    }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func stopLoading() {}
  override func startLoading() {
    let url = request.url!
    if Self.state.shouldFail(port: url.port) {
      client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
      return
    }
    let icon = url.path == "/app/icon"
    let response = HTTPURLResponse(url: url, statusCode: icon ? 404 : 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let body = url.path == "/app" ? #"{"name":"Demo","packageName":"com.example.demo","protocolVersion":4}"# : #"{"tweaks":[]}"#
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

enum SnapOLog {
  static let tracker = 0
}

@main
@MainActor
struct InspectorRecoveryTests {
  static func main() async throws {
    URLProtocol.registerClass(InspectorHTTP.self)
    defer { URLProtocol.unregisterClass(InspectorHTTP.self) }
    let adbService = ADBService()
    let adb = await adbService.exec()
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    let payload = "frozen device transport_id:1\nhealthy device transport_id:2\nstalled device transport_id:3"
    adb.emitDevices(payload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy"] }
    let service = NetworkInspectorService(adbService: adbService, deviceTracker: tracker)
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
      return InspectorHTTP.state.count == 1 && apps.count == 1 && apps.first?.inspectors.count == 2
    }
    let count = adb.forwardCount
    let networkCount = NetworkSession.state.count
    for _ in 0 ..< 50 {
      _ = await service.discoverInspectors().apps
      do {
        _ = try await service.listTweaks(for: frozen)
        fatalError("Frozen inspector should remain disconnected during cooldown")
      } catch NetworkInspectorError.serverNotConnected {}
    }
    precondition(adb.forwardCount == count)
    precondition(NetworkSession.state.count == networkCount)
    precondition(InspectorHTTP.state.count == 1)
    precondition(!adb.scannedDeviceIDs.contains("stalled"))
    print("A device with failed properties is excluded from app discovery")
    _ = try await service.listTweaks(for: healthy)
    print("Both inspector kinds suppress repeated failed connections while healthy inspectors remain usable")

    InspectorHTTP.state.unfreeze()
    NetworkSession.state.unfreeze()
    try await Task.sleep(for: .milliseconds(3200))
    try await eventually { await service.discoverInspectors().apps.count == 2 }
    _ = try await service.listTweaks(for: frozen)
    precondition(adb.forwardCount == count + 1)
    precondition(NetworkSession.state.count == networkCount + 1)
    print("Both inspector kinds reconnect automatically after cooldown")

    await NetworkSession.state.disconnectFrozen()
    try await eventually {
      let apps = await service.discoverInspectors().apps
      return apps.first(where: { $0.deviceId == "frozen" })?.inspectors.map(\.kind) == [.tweaks]
    }
    let disconnectedCount = NetworkSession.state.count
    for _ in 0 ..< 50 {
      _ = await service.discoverInspectors().apps
    }
    precondition(NetworkSession.state.count == disconnectedCount)
    _ = try await service.listTweaks(for: frozen)
    print("A lost network connection enters cooldown without delaying tweaks in the same process")
    await service.stop()

    let restarted = NetworkInspectorService(adbService: adbService, deviceTracker: tracker)
    try await eventually { await restarted.discoverInspectors().apps.count == 2 }
    _ = try await restarted.listTweaks(for: frozen)
    await restarted.stop()
    print("A new service instance can reconnect immediately")

    adb.recoverProperties()
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy", "stalled"] }
    let recovered = NetworkInspectorService(adbService: adbService, deviceTracker: tracker)
    _ = await recovered.discoverInspectors().apps
    precondition(adb.scannedDeviceIDs.contains("stalled"))
    await recovered.stop()
    let failingPayload = "forward-failure device transport_id:4"
    adb.emitDevices(failingPayload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["forward-failure"] }
    let forwardFailure = NetworkInspectorService(adbService: adbService, deviceTracker: tracker)
    let beforeForwardFailure = adb.forwardCount
    for _ in 0 ..< 50 {
      _ = await forwardFailure.discoverInspectors().apps
    }
    precondition(adb.forwardCount == beforeForwardFailure + 1)
    await forwardFailure.stop()
    print("Port forwarding failures enter the same cooldown as failed inspector requests")
    await tracker.stopTracking()
    print("Property failures recover without another device tracking event")
  }

  static func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0 ..< 500 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    fatalError("Condition did not become true")
  }
}

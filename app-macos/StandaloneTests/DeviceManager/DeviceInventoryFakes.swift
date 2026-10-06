import Foundation
import Observation

actor DeviceTracker {
  private var preview: AsyncStream<[Device]>.Continuation?
  private var ready: AsyncStream<[Device]>.Continuation?
  private var currentPreview: [Device]?
  private var currentReady: [Device]?

  func startTracking() async {}
  func retryADBServer() async {}
  func serverStateStream() async -> AsyncStream<ADBServerState> {
    AsyncStream { $0.yield(.online)
      $0.finish()
    }
  }

  func previewDeviceStream() async -> AsyncStream<[Device]> {
    AsyncStream {
      preview = $0
      if let currentPreview { $0.yield(currentPreview) }
    }
  }

  func deviceStream() async -> AsyncStream<[Device]> {
    AsyncStream {
      ready = $0
      if let currentReady { $0.yield(currentReady) }
    }
  }

  func update(_ devices: [Device], ready: Bool = false) {
    currentPreview = devices
    if ready {
      currentReady = devices
      self.ready?.yield(devices)
    }
    preview?.yield(devices)
  }
}

@MainActor
@Observable
final class ADBService {
  let client = ADBClient()
  func exec() async -> ADBClient {
    client
  }
}

@MainActor
@Observable
final class ADBClient {
  let connectionsGate = TestGate()
  let bootGate = TestGate()
  var connectionRequests = 0
  var bootRequests = 0
  var screenshotGate: TestGate?
  var screenshotTargets: [DeviceTarget] = []

  func emulatorConnections(checkBoot: Bool = true) async throws -> [EmulatorConnection] {
    connectionRequests += 1
    await connectionsGate.wait()
    if checkBoot {
      bootRequests += 1
      await bootGate.wait()
    }
    return [EmulatorConnection(serial: "emulator-5554", transportID: "1", state: checkBoot ? .running : .starting)]
  }

  func bound(to target: DeviceTarget) -> DeviceScreenshotClient {
    DeviceScreenshotClient(client: self, target: target)
  }
}

@MainActor
struct DeviceScreenshotClient {
  let client: ADBClient
  let target: DeviceTarget

  func screencapPNG(deviceID: String) async throws -> Data {
    client.screenshotTargets.append(target)
    await client.screenshotGate?.wait()
    _ = try target.requireTransport(for: deviceID)
    return Data([1, 2, 3])
  }
}

@MainActor
@Observable
final class AndroidHostClient {
  var title = "Test Tablet"
  var resolvesSerial = true
  var identityGate = TestGate()
  var identityRequests = 0
  var closeCount = 0
  var actionRequests: [String] = []

  func snapshot(serials: [String]) async throws -> EmulatorInventory {
    if !serials.isEmpty {
      identityRequests += 1
      await identityGate.wait()
    }
    return EmulatorInventory(devices: [ManagedEmulator(
      id: "/synthetic/Test_Tablet.avd", avdName: "Test_Tablet", title: title,
      platform: "API 36", architecture: "arm64-v8a", state: serials.isEmpty ? .unavailable : .offline,
      serial: resolvesSerial ? serials.first : nil
    )])
  }

  func close() { closeCount += 1 }
  func delete(_: String, serials: [String]) async throws -> EmulatorInventory {
    actionRequests.append("delete")
    return try await snapshot(serials: serials)
  }

  func start(_: String, coldBoot _: Bool, serials: [String]) async throws -> EmulatorInventory {
    actionRequests.append("start")
    return try await snapshot(serials: serials)
  }

  func stop(_: String, serial: String) async throws -> EmulatorInventory {
    actionRequests.append("stop")
    return try await snapshot(serials: [serial])
  }
}

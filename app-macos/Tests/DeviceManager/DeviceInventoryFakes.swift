import Foundation
import Observation

@MainActor
@Observable
final class DeviceTracker {
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

  func emulatorConnections(checkBoot: Bool = true) async throws -> [EmulatorConnection] {
    connectionRequests += 1
    await connectionsGate.wait()
    if checkBoot {
      bootRequests += 1
      await bootGate.wait()
    }
    return [EmulatorConnection(serial: "emulator-5554", transportID: "1", state: checkBoot ? .running : .starting)]
  }

  func screencapPNG(deviceID _: String) throws -> Data {
    Data()
  }
}

@MainActor
@Observable
final class AndroidHostClient {
  var title = "Test Tablet"
  var resolvesSerial = true
  var identityGate = TestGate()
  var identityRequests = 0

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

  func close() {}
  func delete(_: String, serials: [String]) async throws -> EmulatorInventory {
    try await snapshot(serials: serials)
  }

  func start(_: String, coldBoot _: Bool, serials: [String]) async throws -> EmulatorInventory {
    try await snapshot(serials: serials)
  }

  func stop(_: String, serial: String) async throws -> EmulatorInventory {
    try await snapshot(serials: [serial])
  }
}

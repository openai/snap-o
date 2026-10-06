import Foundation
import Observation

@Observable
@MainActor
final class DeviceManager {
  var adbServerState: ADBServerState = .online
  func retryADBServer() {}

  private(set) var inventory: DeviceInventory
  var latestDevices: [Device] {
    inventory.ready ?? []
  }

  private let source: (@Sendable () async -> AsyncStream<[Device]>)?

  init(devices: [Device] = [], deviceStream: (@Sendable () async -> AsyncStream<[Device]>)? = nil) {
    inventory = DeviceInventory(connected: devices, ready: devices)
    source = deviceStream
  }

  func start() {}

  func waitForReadyDevices() async -> [Device]? {
    guard !Task.isCancelled else { return nil }
    if let source {
      for await devices in await source() {
        guard !Task.isCancelled else { return nil }
        return devices
      }
      return nil
    }
    for await devices in Observations({ self.inventory.ready }) {
      guard !Task.isCancelled else { return nil }
      if let devices { return devices }
    }
    return nil
  }

  func updateDevices(_ devices: [Device]) {
    inventory = DeviceInventory(connected: devices, ready: devices)
  }

  func updatePreviewDevices(_ devices: [Device]) {
    inventory.connected = devices
  }
}

import Foundation

@MainActor
final class DeviceManager {
  private(set) var latestDevices: [Device]
  private let source: (@Sendable () async -> AsyncStream<[Device]>)?
  private var observers: [UUID: AsyncStream<[Device]>.Continuation] = [:]

  init(devices: [Device] = [], deviceStream: (@Sendable () async -> AsyncStream<[Device]>)? = nil) {
    latestDevices = devices
    source = deviceStream
  }

  func previewDeviceStream() -> AsyncStream<[Device]> {
    deviceStream()
  }

  func deviceStream() -> AsyncStream<[Device]> {
    guard let source else { return localStream() }
    return AsyncStream { continuation in
      let task = Task {
        for await devices in await source() {
          guard !Task.isCancelled else { break }
          continuation.yield(devices)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func localStream() -> AsyncStream<[Device]> {
    let id = UUID()
    return AsyncStream { continuation in
      observers[id] = continuation
      continuation.yield(latestDevices)
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.observers.removeValue(forKey: id) }
      }
    }
  }

  func updateDevices(_ devices: [Device]) {
    latestDevices = devices
    for observer in observers.values {
      observer.yield(devices)
    }
  }
}

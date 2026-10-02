import Foundation

@MainActor
final class DeviceManager {
  var adbServerState: ADBServerState = .online
  func retryADBServer() {}

  private(set) var latestDevices: [Device]
  private var previewDevices: [Device]
  private let source: (@Sendable () async -> AsyncStream<[Device]>)?
  private var observers: [UUID: (preview: Bool, continuation: AsyncStream<[Device]>.Continuation)] = [:]

  init(devices: [Device] = [], deviceStream: (@Sendable () async -> AsyncStream<[Device]>)? = nil) {
    latestDevices = devices
    previewDevices = devices
    source = deviceStream
  }

  func previewDeviceStream() -> AsyncStream<[Device]> {
    stream(preview: true)
  }

  func deviceStream() -> AsyncStream<[Device]> {
    stream(preview: false)
  }

  private func stream(preview: Bool) -> AsyncStream<[Device]> {
    guard let source else { return localStream(preview: preview) }
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

  private func localStream(preview: Bool) -> AsyncStream<[Device]> {
    let id = UUID()
    return AsyncStream { continuation in
      observers[id] = (preview, continuation)
      continuation.yield(preview ? previewDevices : latestDevices)
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.observers.removeValue(forKey: id) }
      }
    }
  }

  func updateDevices(_ devices: [Device]) {
    latestDevices = devices
    previewDevices = devices
    for observer in observers.values {
      observer.continuation.yield(devices)
    }
  }

  func updatePreviewDevices(_ devices: [Device]) {
    previewDevices = devices
    for observer in observers.values where observer.preview {
      observer.continuation.yield(devices)
    }
  }
}

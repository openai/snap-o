import Foundation

protocol DeviceTracking: Sendable {
  func startTracking() async
  func stopTracking() async
  func previewDeviceStream() async -> AsyncStream<[Device]>
  func deviceStream() async -> AsyncStream<[Device]>
  func serverStateStream() async -> AsyncStream<ADBServerState>
  func retryADBServer() async
}

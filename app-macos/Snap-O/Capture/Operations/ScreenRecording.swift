import Foundation

protocol ScreenRecording: AnyObject, Sendable {
  @MainActor var captureWarning: String? { get }
  func stop() async throws
  func waitUntilStopped() async throws
  func save(to destination: URL) async throws
  func remove() async
  func close() async
}

extension ScreenRecording {
  @MainActor var captureWarning: String? {
    nil
  }
}

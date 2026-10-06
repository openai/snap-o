import Foundation

protocol ScreenRecording: AnyObject, Sendable {
  var id: UUID { get }
  func stop() async throws
  func waitUntilStopped() async throws
  func save(to destination: URL) async throws
  func remove() async
  func close() async
}

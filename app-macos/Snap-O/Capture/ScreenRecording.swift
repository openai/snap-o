import Foundation

protocol ScreenRecording: AnyObject, Sendable {
  var id: UUID { get }
  func stop() async throws
  func waitUntilStopped() async throws
  func save(to destination: URL) async throws
  func remove() async
  func close() async
}

final class ADBScreenRecording: ScreenRecording, @unchecked Sendable {
  let id = UUID()
  private let session: RecordingSession
  private let adb: ADBService

  init(session: RecordingSession, adb: ADBService) {
    self.session = session
    self.adb = adb
  }

  func stop() async throws {
    try await adb.exec().signalScreenrecordStop(session: session)
    try await session.waitUntilStopped(timeout: .seconds(5))
  }

  func waitUntilStopped() async throws {
    try await session.waitUntilStopped()
  }

  func save(to destination: URL) async throws {
    try await adb.exec().downloadScreenrecord(session: session, savingTo: destination)
  }

  func remove() async {
    try? await adb.exec().removeScreenrecord(session: session)
  }

  func close() async {
    session.close()
  }
}

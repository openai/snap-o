import Foundation

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
    if let duration = try? await session.recordedDuration() {
      try await ADBRecordingFile.restoreStaticDuration(at: destination, recordedDuration: duration)
    }
  }

  func remove() async {
    try? await adb.exec().removeScreenrecord(session: session)
  }

  func close() async {
    session.close()
  }
}

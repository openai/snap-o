import Foundation
import Observation

@Observable
@MainActor
final class LivePreviewConnection {
  var hasFailed = false
  var restartID = UUID()
  private var acceptsRotation = true
  var rotation: LivePreviewRotation?
  var clipboard: ClipboardSync?
  let thumbnail = LivePreviewThumbnail()
  @ObservationIgnored var cleanupTask: Task<Void, Never>?

  func rotateDevice(deviceID: String, left: Bool) async throws {
    try Task.checkCancellation()
    guard acceptsRotation else { throw CancellationError() }
    let session = rotation ?? LivePreviewRotation(deviceID: deviceID)
    rotation = session
    try await session.rotate(left: left)
    try Task.checkCancellation()
    if !EmulatorGRPCEndpoint.isEmulator(deviceID) { restartID = UUID() }
  }

  func stopRotation() async {
    acceptsRotation = false
    await rotation?.stop()
  }
}

import Foundation

actor ADBService {
  private let video: URL
  private var sessions: [String: RecordingSession] = [:]
  private var screenshotGate: TestGate?
  private var deviceScreenshotGates: [String: TestGate] = [:]
  private(set) var screenshotRequests: [String] = []
  private(set) var densityRequests: [String] = []
  private var downloadGate: TestGate?
  private var touchRestorationGate: TestGate?
  private var unavailable: Set<String> = []
  private var failedStops: Set<String> = []
  private(set) var stops: [String] = []
  private(set) var removedRecordings: [String] = []
  private(set) var touchSettings: [String: Bool] = [:] {
    didSet { testChanges.signal() }
  }

  init(video: URL) {
    self.video = video
  }

  func bound(to _: DeviceTarget) -> ADBService {
    self
  }

  func exec() -> ADBService {
    self
  }

  func blockScreenshots(on gate: TestGate) {
    screenshotGate = gate
  }

  func blockScreenshot(for deviceID: String, on gate: TestGate) {
    deviceScreenshotGates[deviceID] = gate
  }

  func screencapPNG(deviceID: String) async throws -> Data {
    screenshotRequests.append(deviceID)
    await screenshotGate?.wait()
    await deviceScreenshotGates[deviceID]?.wait()
    try Task.checkCancellation()
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1kAAAAASUVORK5CYII="
    guard let image = Data(base64Encoded: encoded) else {
      preconditionFailure("Invalid test image")
    }
    return image
  }

  func displayDensity(deviceID: String) throws -> Int {
    densityRequests.append(deviceID)
    return 160
  }

  func withTimeout(_: Duration?) -> ADBService {
    self
  }

  func getShowTouches(deviceID: String) throws -> Bool {
    touchSettings[deviceID] ?? false
  }

  func blockTouchRestoration(on gate: TestGate) {
    touchRestorationGate = gate
  }

  func setShowTouches(deviceID: String, enabled: Bool) async throws {
    if !enabled { await touchRestorationGate?.wait() }
    touchSettings[deviceID] = enabled
  }

  func startScreenrecord(deviceID: String, bugReport _: Bool) throws -> RecordingSession {
    let session = RecordingSession(deviceID: deviceID)
    sessions[deviceID] = session
    return session
  }

  func endUnexpectedly(_ deviceID: String) {
    sessions[deviceID]?.end(error: ADBError.protocolFailure("Recording stream failed"))
  }

  func failCollection(_ deviceID: String) {
    unavailable.insert(deviceID)
  }

  func failStop(_ deviceID: String) {
    failedStops.insert(deviceID)
  }

  func signalScreenrecordStop(session: RecordingSession) throws {
    stops.append(session.deviceID)
    if failedStops.contains(session.deviceID) {
      throw ADBError.requestTimedOut("Recording stop timed out")
    }
    session.end()
  }

  func blockDownload(on gate: TestGate) {
    downloadGate = gate
  }

  func downloadScreenrecord(session: RecordingSession, savingTo url: URL) async throws {
    await downloadGate?.wait()
    guard !unavailable.contains(session.deviceID) else {
      throw ADBError.protocolFailure("Recording file unavailable")
    }
    try FileManager.default.copyItem(at: video, to: url)
  }

  func removeScreenrecord(session: RecordingSession) throws {
    removedRecordings.append(session.deviceID)
  }
}

enum EmulatorGRPCEndpoint {
  static func isEmulator(_ serial: String) -> Bool {
    serial.hasPrefix("emulator-")
  }
}

enum StartupCaptureMode { case screenshot, livePreview }

@MainActor
final class EmulatorControlsController {}

@MainActor
final class LivePreviewAttachment {
  func close() async {}
}

@MainActor
final class LivePreviewService {
  func attach(
    to device: Device, makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController?
  ) -> LivePreviewAttachment? {
    preconditionFailure("Screenshot startup tests must not start live preview")
  }
}

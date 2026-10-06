import Foundation
import Observation

/// The pane owns navigation. These controllable dependencies supply device and capture events.
@Observable
@MainActor
final class DeviceManager {
  var inventory = DeviceInventory()
  var adbServerState = ADBServerState.online
  var resolveRequest: (@MainActor (DeviceOpenRequest, (String) -> Void) async throws -> String)?
  var screenshotTargets: [DeviceTarget] = []
  func screenshot(for target: DeviceTarget) async throws -> Data {
    screenshotTargets.append(target)
    return Data("thumbnail".utf8)
  }

  func start() {}
  func retryADBServer() {}
  func resolve(_ request: DeviceOpenRequest, progress: (String) -> Void) async throws -> String {
    if let resolveRequest { return try await resolveRequest(request, progress) }
    if case .serial(let serial) = request { return serial }
    throw CancellationError()
  }
}

actor ADBService {}

enum StartupCaptureMode { case livePreview, screenshot }
@MainActor
final class AppSettings {
  static let shared = AppSettings()
  var lastViewedDeviceID: String?
  var startupCaptureMode = StartupCaptureMode.livePreview
  var showTouchesDuringCapture = false
  var recordAsBugReport = false
}

@MainActor
final class EmulatorControlsController {}

@Observable
@MainActor
final class PreviewStatus { var display: DisplayInfo? }

@Observable
@MainActor
final class LivePreviewAttachment {
  let id = UUID()
  let target: DeviceTarget
  let preview: PreviewStatus? = PreviewStatus()
  var isClosed = false
  var isPaneVisible = true
  init(_ target: DeviceTarget) {
    self.target = target
  }

  func setVisible(_ visible: Bool) {}
  func setPaneVisible(_ visible: Bool) {
    isPaneVisible = visible
  }

  func close() async {
    isClosed = true
  }

  func screenshot() async throws -> Data {
    throw CancellationError()
  }

  func sendKey(_ key: String) async throws {}
}

@MainActor
final class LivePreviewService {
  var attachments: [LivePreviewAttachment] = []
  func attach(
    to device: Device, makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController?
  ) -> LivePreviewAttachment? {
    guard let target = device.connection else { return nil }
    let attachment = LivePreviewAttachment(target)
    attachments.append(attachment)
    return attachment
  }
}

@MainActor
final class StartupCapturePreparation {
  init(
    screenshots: @escaping @MainActor ([Device]) -> ScreenshotCapture,
    livePreview: LivePreviewService,
    makeEmulatorControls: @escaping @MainActor (DeviceTarget) -> EmulatorControlsController?
  ) {}
  func claimLivePreview(for device: Device) -> LivePreviewAttachment? {
    nil
  }

  func claimScreenshots(for devices: [Device]) -> ScreenshotCapture? {
    nil
  }

  func discard() async {}
}

@Observable
@MainActor
final class ScreenshotCapture: CaptureBatch {
  let id = UUID()
  let kind = CaptureKind.screenshots
  let items: [CaptureItem]
  var isComplete = false
  var closeCount = 0
  init(_ devices: [Device]) {
    items = devices.map(CaptureItem.init)
  }

  func start() {}
  func close() async {
    closeCount += 1
    isComplete = true
  }
}

@Observable
@MainActor
final class RecordingCapture: CaptureBatch {
  enum Phase { case starting, recording, finishing }
  let id = UUID()
  let kind = CaptureKind.recording
  let items: [CaptureItem]
  let options: RecordingOptions
  var phase = Phase.starting
  var isComplete = false
  var closeCount = 0
  var closeGate: TestSuspension?
  init(_ devices: [Device], options: RecordingOptions) {
    items = devices.map(CaptureItem.init)
    self.options = options
  }

  func start() {
    phase = .recording
  }

  func requestFinish() {
    phase = .finishing
  }

  func close() async {
    closeCount += 1
    if let closeGate { try? await closeGate.wait() }
    isComplete = true
  }
}

@Observable
@MainActor
final class ToolSession {
  init(adbService: ADBService? = nil, deviceManager: DeviceManager? = nil) {}
  private(set) var starts = 0
  private(set) var isVisible = false
  private(set) var isClosed = false
  func setVisible(_ visible: Bool) {
    guard !isClosed else { return }
    isVisible = visible
    if visible, starts == 0 { starts += 1 }
  }

  func stop() async {
    isClosed = true
  }
}

import SwiftUI

private let log = SnapOLog.recording

@MainActor
@Observable
final class CaptureWindowCoordinator {
  let captureVM: CaptureViewModel

  private let fileStore: FileStore
  private let adb: ADBClient
  let settings: AppSettings

  let devices = DeviceSelection()

  var canCapture: Bool {
    devices.currentDevice != nil && captureVM.canCapture
  }

  init(services: AppServices) {
    settings = services.settings
    adb = services.adbService.client
    fileStore = services.fileStore

    captureVM = CaptureViewModel(
      adb: adb,
      store: fileStore,
      settings: settings,
      captureService: services.captureService
    )
  }

  func handle(url: URL) {
    // snapo://record or snapo://capture
    guard let host = url.host, let cmd = SnapOCommand(rawValue: host) else { return }
    NSApp.activate(ignoringOtherApps: true)
    captureVM.pendingCommand = cmd
    Task { await refreshPreview() }
  }

  func refreshPreview() async {
    if let deviceID = devices.currentDevice?.id {
      await captureVM.refreshPreview(for: deviceID)
    }
  }

  func startRecording() async {
    if let deviceID = devices.currentDevice?.id {
      log.info("Start recording for device=\(deviceID, privacy: .public)")
      await captureVM.startRecording(for: deviceID)
    }
  }

  func stopRecording() async {
    await captureVM.stopRecording()
  }

  func startLivePreview() async {
    if let deviceID = devices.currentDevice?.id {
      log.info("Start live preview for device=\(deviceID, privacy: .public)")
      await captureVM.startLivePreview(for: deviceID)
    }
  }

  func stopLivePreview(withRefresh refresh: Bool = false) async {
    await captureVM.stopLivePreview(withRefresh: refresh)
  }

  var canStartRecordingNow: Bool {
    devices.currentDevice != nil && captureVM.canStartRecording
  }

  var canStartLivePreviewNow: Bool {
    devices.currentDevice != nil && captureVM.canStartLivePreview
  }

  var showTouchesDuringCapture: Bool {
    get { settings.showTouchesDuringCapture }
    set { settings.showTouchesDuringCapture = newValue }
  }

  // MARK: - Device Selection

  func onDevicesChanged(_ list: [Device]) {
    devices.updateDevices(list)
  }

  var currentDevice: Device? { devices.currentDevice }

  func selectNextDevice() {
    devices.selectNext()
  }

  func selectPreviousDevice() {
    devices.selectPrevious()
  }
}

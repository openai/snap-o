import SwiftUI

private let log = SnapOLog.recording

@MainActor
@Observable
final class CaptureWindowCoordinator {
  let captureVM: CaptureViewModel
  let deviceVM: DeviceListViewModel

  private let appCoordinator: AppCoordinator
  private let fileStore: FileStore
  private let adb: ADBClient
  let settings: AppSettings

  var canCapture: Bool {
    deviceVM.currentDevice != nil && !captureVM.isRecording && !captureVM.isLoading
  }

  init(appCoordinator: AppCoordinator) {
    self.appCoordinator = appCoordinator
    settings = appCoordinator.settings
    adb = appCoordinator.adbClient
    fileStore = appCoordinator.fileStore

    deviceVM = DeviceListViewModel()
    captureVM = CaptureViewModel(
      adb: adb,
      store: fileStore,
      settings: settings
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
    if let deviceID = deviceVM.currentDevice?.id {
      await captureVM.refreshPreview(for: deviceID)
    }
  }

  func startRecording() async {
    if let deviceID = deviceVM.currentDevice?.id {
      log.info("Start recording for device=\(deviceID, privacy: .public)")
      await captureVM.startRecording(for: deviceID)
    }
  }

  func stopRecording() async {
    await captureVM.stopRecording()
  }

  func startLivePreview() async {
    if let deviceID = deviceVM.currentDevice?.id {
      log.info("Start live preview for device=\(deviceID, privacy: .public)")
      await captureVM.startLivePreview(for: deviceID)
    }
  }

  func stopLivePreview(refreshPreview: Bool = false) {
    captureVM.stopLivePreview(refreshPreview: refreshPreview)
  }

  func promptForADBPath() async {
    let mgr = ADBPathManager()
    await MainActor.run {
      mgr.promptForADBPath()
    }
    let chosen = ADBPathManager.lastKnownADBURL()
    await adb.setURL(chosen)
  }

  var canStartRecordingNow: Bool {
    deviceVM.currentDevice != nil && captureVM.canStartRecording
  }

  var canStartLivePreviewNow: Bool {
    deviceVM.currentDevice != nil && captureVM.canStartLivePreview
  }

  var showTouchesDuringCapture: Bool {
    get { settings.showTouchesDuringCapture }
    set { settings.showTouchesDuringCapture = newValue }
  }
}

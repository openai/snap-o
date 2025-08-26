import SwiftUI

private let log = SnapOLog.recording

@MainActor
@Observable
final class CaptureWindowCoordinator {
  let captureVM: CaptureViewModel
  let deviceVM: DeviceListViewModel

  private let fileStore: FileStore
  private let recordingService: RecordingService
  private let recordingStore: RecordingStore
  private let adb: ADBClient

  var canCapture: Bool {
    deviceVM.currentDevice != nil && !captureVM.isRecording && !captureVM.isLoading
  }

  init(adbClient: ADBClient, fileStore: FileStore, recordingService: RecordingService, recordingStore: RecordingStore) {
    adb = adbClient
    self.fileStore = fileStore
    self.recordingService = recordingService
    self.recordingStore = recordingStore

    deviceVM = DeviceListViewModel()
    captureVM = CaptureViewModel(adb: adbClient, store: fileStore, recordingService: recordingService)
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

  func promptForADBPath() async {
    let mgr = ADBPathManager()
    await MainActor.run {
      mgr.promptForADBPath()
    }
    let chosen = ADBPathManager.lastKnownADBURL()
    await adb.setURL(chosen)
  }

  var isDeviceRecording: Bool {
    guard let id = deviceVM.currentDevice?.id else { return false }
    return recordingStore.isRecording(deviceID: id)
  }

  var canStartRecordingNow: Bool {
    deviceVM.currentDevice != nil && captureVM.canStartRecording && !isDeviceRecording
  }
}

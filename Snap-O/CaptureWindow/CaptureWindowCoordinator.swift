import SwiftUI

private let log = SnapOLog.recording

@MainActor
@Observable
final class CaptureWindowCoordinator {
  let captureVM: CaptureViewModel

  private let fileStore: FileStore
  private let adb: ADBClient
  let settings: AppSettings

  var devices: [Device] = []
  var selectedDeviceID: String?

  var canCapture: Bool {
    currentDevice != nil && !captureVM.isRecording && !captureVM.isLoading
  }

  init(services: AppServices) {
    settings = services.settings
    adb = services.adbService.client
    fileStore = services.fileStore

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
    if let deviceID = currentDevice?.id {
      await captureVM.refreshPreview(for: deviceID)
    }
  }

  func startRecording() async {
    if let deviceID = currentDevice?.id {
      log.info("Start recording for device=\(deviceID, privacy: .public)")
      await captureVM.startRecording(for: deviceID)
    }
  }

  func stopRecording() async {
    await captureVM.stopRecording()
  }

  func startLivePreview() async {
    if let deviceID = currentDevice?.id {
      log.info("Start live preview for device=\(deviceID, privacy: .public)")
      await captureVM.startLivePreview(for: deviceID)
    }
  }

  func stopLivePreview(refreshPreview: Bool = false) {
    captureVM.stopLivePreview(refreshPreview: refreshPreview)
  }

  var canStartRecordingNow: Bool {
    currentDevice != nil && captureVM.canStartRecording
  }

  var canStartLivePreviewNow: Bool {
    currentDevice != nil && captureVM.canStartLivePreview
  }

  var showTouchesDuringCapture: Bool {
    get { settings.showTouchesDuringCapture }
    set { settings.showTouchesDuringCapture = newValue }
  }

  // MARK: - Device Selection

  var currentDevice: Device? {
    guard let id = selectedDeviceID else { return nil }
    return devices.first { $0.id == id }
  }

  func onDevicesChanged(_ list: [Device]) {
    devices = list
    if let sel = selectedDeviceID,
       list.contains(where: { $0.id == sel }) {
      // keep selection
    } else {
      selectedDeviceID = list.first?.id
    }
  }

  private var currentIndex: Int? {
    guard let id = selectedDeviceID else { return nil }
    return devices.firstIndex { $0.id == id }
  }

  func selectNextDevice() {
    guard !devices.isEmpty else { selectedDeviceID = nil
      return
    }
    guard let idx = currentIndex else { selectedDeviceID = devices.first?.id
      return
    }
    selectedDeviceID = devices[(idx + 1) % devices.count].id
  }

  func selectPreviousDevice() {
    guard !devices.isEmpty else { selectedDeviceID = nil
      return
    }
    guard let idx = currentIndex else { selectedDeviceID = devices.first?.id
      return
    }
    selectedDeviceID = devices[(idx - 1 + devices.count) % devices.count].id
  }
}

import Foundation

final actor AppServices {
  static let shared = AppServices()

  let adbService: ADBService
  let deviceTracker: DeviceTracker
  let fileStore: FileStore
  let captureService: CaptureService

  init() {
    adbService = ADBService()
    deviceTracker = DeviceTracker(adbService: adbService)
    fileStore = FileStore()
    captureService = CaptureService(adb: adbService, fileStore: fileStore)
  }

  func start() async {
    Perf.step(.appFirstSnapshot, "services start")
    Perf.step(.appFirstSnapshot, "start tracking")
    deviceTracker.startTracking()

    Task {
      Perf.step(.appFirstSnapshot, "start preload task")
      let stream = deviceTracker.deviceStream()
      Perf.step(.appFirstSnapshot, "query device stream")
      for await devices in stream {
        guard let deviceID = devices.first?.id else { continue }
        Perf.step(.appFirstSnapshot, "have first device")
        await captureService.preloadScreenshot(for: deviceID)
        break
      }
    }
  }
}

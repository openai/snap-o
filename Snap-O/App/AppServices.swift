import Foundation

final actor AppServices {
  static let shared = AppServices()

  let adbService: ADBService
  let deviceTracker: DeviceTracker
  let fileStore: FileStore
  let captureService: CaptureService
  let networkInspector: NetworkInspectorService

  init() {
    adbService = ADBService()
    deviceTracker = DeviceTracker(adbService: adbService)
    fileStore = FileStore()
    captureService = CaptureService(
      adb: adbService,
      fileStore: fileStore,
      deviceTracker: deviceTracker
    )
    networkInspector = NetworkInspectorService(
      adbService: adbService,
      deviceTracker: deviceTracker
    )
  }

  func start() async {
    Perf.step(.appFirstSnapshot, "services start")
    deviceTracker.startTracking()
    await networkInspector.start()

    Task {
      Perf.step(.appFirstSnapshot, "start preload task")
      let stream = deviceTracker.deviceStream()
      Perf.step(.appFirstSnapshot, "query device stream")
      for await devices in stream where !devices.isEmpty {
        await captureService.preloadScreenshots()
        break
      }
    }
  }
}

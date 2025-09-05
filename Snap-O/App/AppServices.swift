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
    await adbService.ensureConfigured()
    deviceTracker.startTracking()
  }
}

import AppKit
import SwiftUI

@MainActor
final class AppServices {
  let adbService: ADBService
  let deviceService: DeviceService
  let fileStore: FileStore
  let settings: AppSettings
  let captureService: CaptureService

  init() {
    settings = AppSettings()
    adbService = ADBService()
    deviceService = DeviceService(adbService: adbService)
    fileStore = FileStore()
    captureService = CaptureService(adb: adbService.client, fileStore: fileStore)
  }

  func start() async {
    await adbService.ensureConfigured()
    await deviceService.start()
  }
}

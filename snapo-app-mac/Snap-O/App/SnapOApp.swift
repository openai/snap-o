import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private let fileStore: FileStore
  private let captureService: CaptureService
  private let settings = AppSettings.shared
  private let updateCoordinator = UpdateCoordinator.shared

  init() {
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")

    adbService = ADBService()
    let deviceTracker = DeviceTracker(adbService: adbService)
    self.deviceTracker = deviceTracker
    fileStore = FileStore()
    let captureService = CaptureService(
      adb: adbService,
      fileStore: fileStore,
      deviceTracker: deviceTracker
    )
    self.captureService = captureService

    Task.detached(priority: .userInitiated) {
      Perf.step(.appFirstSnapshot, "services start")
      deviceTracker.startTracking()

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

  var body: some Scene {
    WindowGroup {
      CaptureWindow(
        captureService: captureService,
        deviceTracker: deviceTracker,
        fileStore: fileStore,
        adbService: adbService
      )
      .handlesExternalEvents(
        preferring: Set(["record", "capture", "livepreview", "check-updates", "check-for-updates"]),
        allowing: Set(["*"])
      )
    }
    .environment(settings)
    .defaultSize(width: 480, height: 480)
    .handlesExternalEvents(matching: Set(["record", "capture", "livepreview"]))
    .commands {
      SnapOCommands(
        settings: settings,
        adbService: adbService,
        updaterController: updateCoordinator.updaterController
      )
    }

    Window("Logcat Viewer", id: LogcatWindowID.main) {
      LogcatWindowRoot(adbService: adbService, deviceTracker: deviceTracker)
    }
    .defaultSize(width: 1000, height: 600)
    .handlesExternalEvents(matching: Set(["logcat"]))
  }
}

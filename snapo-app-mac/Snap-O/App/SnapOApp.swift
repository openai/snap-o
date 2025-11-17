import Sparkle
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
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

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
    }
    .environment(settings)
    .defaultSize(width: 480, height: 480)
    .windowToolbarStyle(.unified)
    .commands {
      SnapOCommands(
        settings: settings,
        adbService: adbService,
        updaterController: updaterController
      )
    }

    Window("Network Inspector (Alpha)", id: NetworkInspectorWindowID.main) {
      NetworkInspectorWindowRoot(
        adbService: adbService,
        deviceTracker: deviceTracker
      )
    }
    .environment(settings)
    .defaultSize(width: 960, height: 520)

    Window("Logcat Viewer", id: LogcatWindowID.main) {
      LogcatWindowRoot(adbService: adbService, deviceTracker: deviceTracker)
    }
    .defaultSize(width: 1000, height: 600)
  }
}

private struct NetworkInspectorWindowRoot: View {
  @StateObject private var store: NetworkInspectorStore
  @Environment(AppSettings.self)
  private var settings

  init(
    adbService: ADBService,
    deviceTracker: DeviceTracker
  ) {
    _store = StateObject(
      wrappedValue: NetworkInspectorStore(
        service: NetworkInspectorService(
          adbService: adbService,
          deviceTracker: deviceTracker
        )
      )
    )
  }

  var body: some View {
    NetworkInspectorView(store: store)
      .onAppear {
        settings.shouldReopenNetworkInspector = true
      }
      .onDisappear {
        guard settings.isAppTerminating != true else { return }
        settings.shouldReopenNetworkInspector = false
      }
  }
}

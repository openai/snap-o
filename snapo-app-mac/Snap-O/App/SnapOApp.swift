import Sparkle
import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices
  private let settings = AppSettings.shared
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  init() {
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")

    let services = AppServices.shared
    self.services = services

    Task.detached(priority: .userInitiated) {
      await services.start()
    }
  }

  var body: some Scene {
    WindowGroup {
      CaptureWindow()
    }
    .environment(settings)
    .defaultSize(width: 480, height: 480)
    .windowToolbarStyle(.unified)
    .commands {
      SnapOCommands(
        settings: settings,
        adbService: services.adbService,
        updaterController: updaterController
      )
    }

    Window("Network Inspector (Alpha)", id: NetworkInspectorWindowID.main) {
      NetworkInspectorWindowRoot(services: services)
    }
    .environment(settings)
    .defaultSize(width: 960, height: 520)

    Window("Logcat Viewer (alpha)", id: LogCatWindowID.main) {
      LogCatWindowRoot(services: services)
    }
    .defaultSize(width: 1000, height: 600)
  }
}

private struct NetworkInspectorWindowRoot: View {
  @StateObject private var store: NetworkInspectorStore
  @Environment(AppSettings.self)
  private var settings

  init(services: AppServices) {
    _store = StateObject(wrappedValue: NetworkInspectorStore(service: NetworkInspectorService(
      adbService: services.adbService,
      deviceTracker: services.deviceTracker
    )))
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

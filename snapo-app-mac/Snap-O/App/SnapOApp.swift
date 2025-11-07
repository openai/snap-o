import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices
  private let settings: AppSettings

  init() {
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")

    let services = AppServices.shared
    self.services = services

    settings = AppSettings.shared

    Task.detached(priority: .userInitiated) {
      await services.start()
    }
  }

  var body: some Scene {
    WindowGroup {
      CaptureWindow()
    }
    .defaultSize(width: 480, height: 480)
    .windowToolbarStyle(.unified)
    .commands {
      SnapOCommands(
        settings: settings,
        adbService: services.adbService
      )
    }

    Window("Network Inspector (Alpha)", id: NetworkInspectorWindowID.main) {
      NetworkInspectorWindowRoot(services: services)
    }
    .defaultSize(width: 960, height: 520)

    Window("Logcat Viewer (alpha)", id: LogLionWindowID.main) {
      LogLionWindowRoot(services: services)
    }
    .defaultSize(width: 1000, height: 600)
  }
}

private struct NetworkInspectorWindowRoot: View {
  @StateObject private var store: NetworkInspectorStore
  @ObservedObject private var settings = AppSettings.shared

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

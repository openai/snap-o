import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices
  private let settings: AppSettings
  @StateObject private var networkInspectorStore: NetworkInspectorStore

  init() {
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")

    let services = AppServices.shared
    self.services = services

    settings = AppSettings.shared
    let inspectorService = NetworkInspectorService(
      adbService: services.adbService,
      deviceTracker: services.deviceTracker
    )
    _networkInspectorStore = StateObject(wrappedValue: NetworkInspectorStore(service: inspectorService))

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

    Window("Network Inspector", id: NetworkInspectorWindowID.main) {
      NetworkInspectorView(store: networkInspectorStore)
    }
    .defaultSize(width: 960, height: 520)
  }
}

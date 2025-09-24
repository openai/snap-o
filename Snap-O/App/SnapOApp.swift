import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices
  private let settings: AppSettings
  private let networkInspectorController: NetworkInspectorWindowController

  init() {
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")

    let services = AppServices.shared
    self.services = services

    settings = AppSettings.shared

    networkInspectorController = NetworkInspectorWindowController(
      service: services.networkInspector
    )

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
        adbService: services.adbService,
        networkInspectorController: networkInspectorController
      )
    }
  }
}

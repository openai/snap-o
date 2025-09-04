import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices
  private let settings: AppSettings

  init() {
    let services = AppServices.shared
    self.services = services

    settings = AppSettings.shared

    // Perf: App start → first snapshot rendered (compiled out when disabled)
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")

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
  }
}

import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices

  init() {
    let services = AppServices()
    self.services = services
    Task { await services.start() }
  }

  var body: some Scene {
    WindowGroup {
      CaptureWindow(services: services)
    }
    .defaultSize(width: 480, height: 480)
    .windowToolbarStyle(.unified)
    .commands {
      SnapOCommands(
        settings: services.settings,
        adbService: services.adbService
      )
    }
  }
}

import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let coordinator = AppCoordinator()

  var body: some Scene {
    WindowGroup {
      CaptureWindow(appCoordinator: coordinator)
        .task { await coordinator.trackDevices() }
    }
    .defaultSize(width: 480, height: 480)
    .windowToolbarStyle(.unified)
    .commands {
      SnapOCommands(settings: coordinator.settings)
    }
  }
}

import Sparkle
import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let services: AppServices
  private let settings: AppSettings
  private let updaterController: SPUStandardUpdaterController

  init() {
    let services = AppServices.shared
    self.services = services

    settings = AppSettings.shared

    // Initialize Sparkle updater controller; starts checks automatically
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

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
      CommandGroup(after: .appInfo) {
        CheckForUpdatesView(updater: updaterController.updater)
      }
      SnapOCommands(
        settings: settings,
        adbService: services.adbService
      )
    }
  }
}

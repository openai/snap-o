import SwiftUI

@main
struct SnapOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  var appDelegate

  private let runtime: AppRuntime
  private let settings = AppSettings.shared
  private let updateCoordinator = UpdateCoordinator.shared

  init() {
    Perf.start(.appFirstSnapshot, name: "App Start → First Snapshot")
    let runtime = AppRuntime()
    self.runtime = runtime
    appDelegate.prepareForTermination = {
      await runtime.shutdown()
    }
    runtime.start()
  }

  var body: some Scene {
    WindowGroup(
      id: WorkspaceWindowID.main,
      for: WorkspaceWindowConfiguration.self,
      content: { configuration in
        CaptureWindow(
          captureServices: runtime.captureServices,
          deviceManager: runtime.deviceManager,
          fileStore: runtime.fileStore,
          adbService: runtime.adbService,
          initialWorkspace: configuration.wrappedValue.workspace
        )
        .handlesExternalEvents(
          preferring: Set(["record", "capture", "livepreview", "check-updates", "check-for-updates"]),
          allowing: Set(["*"])
        )
      },
      defaultValue: {
        WorkspaceWindowConfiguration(workspace: .persisted())
      }
    )
    .environment(settings)
    .environment(runtime.captureHistory)
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 480, height: 480)
    .handlesExternalEvents(matching: Set(["record", "capture", "livepreview"]))
    .commands {
      SnapOCommands(
        history: runtime.captureHistory,
        settings: settings,
        updaterController: updateCoordinator.updaterController
      )
    }

    Window("Device Manager", id: "device-manager") {
      DeviceManagerWindow(manager: runtime.deviceManager)
    }
    .defaultSize(width: 680, height: 420)
    .windowResizability(.contentMinSize)
    .commandsRemoved()

    Window("Capture History", id: "capture-history") {
      CaptureHistoryWindow(history: runtime.captureHistory, fileStore: runtime.fileStore)
    }
    .defaultSize(width: 800, height: 650)
    .windowResizability(.contentMinSize)
    .commandsRemoved()
  }
}

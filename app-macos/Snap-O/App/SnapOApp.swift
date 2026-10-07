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
    appDelegate.unfinishedTerminationWork = { runtime.unfinishedCleanup }
    runtime.start()
  }

  var body: some Scene {
    WindowGroup(
      id: WorkspaceWindowID.main,
      for: WorkspaceWindowConfiguration.self,
      content: { configuration in
        CaptureWindow(
          workspaces: runtime.workspaces,
          initialWorkspace: configuration.wrappedValue.workspace
        )
        .modifier(WorkspaceWindowLauncher())
      },
      defaultValue: {
        WorkspaceWindowConfiguration(workspace: .persisted())
      }
    )
    .environment(settings)
    .environment(runtime.captureHistory)
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 480, height: 480)
    .commands {
      SnapOCommands(
        history: runtime.captureHistory,
        settings: settings,
        updaterController: updateCoordinator.updaterController
      )
    }

    Window("Device Manager", id: "device-manager") {
      DeviceManagerWindow(manager: runtime.deviceManager)
        .modifier(WorkspaceWindowLauncher())
    }
    .defaultSize(width: 680, height: 420)
    .windowResizability(.contentMinSize)
    .commandsRemoved()

    Window("ADB Servers", id: "adb-servers") {
      ADBServersWindow(servers: runtime.adbServers)
    }
    .defaultSize(width: 580, height: 380)
    .windowResizability(.contentMinSize)
    .commandsRemoved()

    Window("Capture History", id: "capture-history") {
      CaptureHistoryWindow(history: runtime.captureHistory, fileStore: runtime.fileStore)
        .modifier(WorkspaceWindowLauncher())
    }
    .defaultSize(width: 800, height: 650)
    .windowResizability(.contentMinSize)
    .commandsRemoved()
  }
}

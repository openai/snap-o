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
    let enableServer: (ADBServerID, DeviceLinkServer) async throws -> Void = { id, connection in
      guard case .remote(let profileID) = id,
            let profile = runtime.adbServers.profiles.first(where: { $0.id == profileID }),
            runtime.adbServers.deviceLinkServers[id]?.server == connection else {
        throw DeviceOpenError(message: "The server configuration changed. Open the link again to review it.")
      }
      try await runtime.adbServers.setEnabled(true, for: profile)
    }
    let addServer: (DeviceLinkServer) async throws -> (id: ADBServerID, server: DeviceLinkServer)? = { server in
      guard let profile = await DeviceLinkDialogs.addServer(server: server, save: runtime.adbServers.save),
            case .ssh(let configuration) = profile.connection else { return nil }
      return (.remote(profile.id), .ssh(destination: configuration.destination, port: configuration.port, adbPort: configuration.adbPort))
    }
    let authorization = DeviceLinkAuthorization(
      servers: { runtime.adbServers.deviceLinkServers },
      confirmEnable: DeviceLinkDialogs.confirmEnable,
      confirmAdd: DeviceLinkDialogs.confirmAdd,
      addServer: addServer,
      enable: enableServer
    )
    SnapOCommandCoordinator.shared.requiresDeviceLinkApproval = authorization.requiresApproval
    SnapOCommandCoordinator.shared.authorizeDeviceLink = { request in
      do { return try await authorization.authorize(request) } catch {
        DeviceLinkDialogs.showError(error)
        return nil
      }
    }
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
    // AppDelegate routes URLs and opens a workspace only when needed.
    .handlesExternalEvents(matching: [])
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

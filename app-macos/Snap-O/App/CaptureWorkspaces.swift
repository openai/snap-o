import Foundation

/// Creates window sessions and waits for them to close when the app quits.
@MainActor
final class CaptureWorkspaces {
  let deviceManager: DeviceManager
  private let captureServices: CaptureServices
  private let fileStore: FileStore
  private let adbService: ADBService
  private let history: CaptureHistory
  private let sessions = NSHashTable<CaptureWindowSession>.weakObjects()
  private var shutdownTask: Task<Void, Never>?

  init(
    captureServices: CaptureServices, deviceManager: DeviceManager, fileStore: FileStore,
    adbService: ADBService, history: CaptureHistory
  ) {
    self.captureServices = captureServices
    self.deviceManager = deviceManager
    self.fileStore = fileStore
    self.adbService = adbService
    self.history = history
  }

  func makeSession(initialWorkspace: WorkspaceLayoutSnapshot? = nil) -> CaptureWindowSession {
    let session = CaptureWindowSession(
      capture: CapturePaneSession(
        services: captureServices, devices: deviceManager, fileStore: fileStore, history: history
      ),
      tools: ToolSession(adbService: adbService, deviceManager: deviceManager),
      workspace: WorkspaceLayoutController(snapshot: initialWorkspace)
    )
    sessions.add(session)
    // SwiftUI may construct another view while termination is already in progress.
    if shutdownTask != nil { session.close() }
    return session
  }

  @discardableResult
  func beginShutdown() -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    let cleanups = sessions.allObjects.map { $0.close() }
    let task = Task {
      for cleanup in cleanups {
        await cleanup.value
      }
    }
    shutdownTask = task
    return task
  }

  func shutdown() async {
    await beginShutdown().value
  }
}

import Foundation

/// Starts shared services and waits for them to stop when the app quits.
@MainActor
final class AppRuntime {
  let deviceManager: DeviceManager
  let adbService: ADBService
  let adbServers: ADBServers
  private let deviceTracker: any DeviceTracking
  let fileStore: FileStore
  private let livePreview: LivePreviewService
  private let startupDiscovery: StartupCaptureDiscovery
  let workspaces: CaptureWorkspaces
  let captureHistory: CaptureHistory

  private let captureCoordinator: CaptureCoordinator

  private enum Cleanup: String, CaseIterable {
    case startup = "startup preparation"
    case workspaces
    case deviceManager = "device management"
    case deviceTracker = "device tracking"
    case livePreview = "live preview"
    case reservations = "capture reservations"
    case files = "file exports"
    case history = "History"
  }

  private var pendingCleanup: Set<Cleanup> = []
  var unfinishedCleanup: [String] {
    Cleanup.allCases.filter { pendingCleanup.contains($0) }.map(\.rawValue)
  }

  private var hasStarted = false
  private var shutdownTask: Task<Void, Never>?

  init() {
    let hostClient = AndroidHostClient()
    let localTracker = DeviceTracker(connect: { ADBClient() }, recoverADBServer: {
      try await hostClient.ensureADBServerRunning()
    })
    let serverStore = ADBServerStore(defaults: .standard)
    let profiles: [RemoteADBServer]
    var serverError: String?
    do { profiles = try serverStore.load() } catch {
      profiles = []
      serverError = "Could not load saved ADB servers. " + error.localizedDescription
    }
    let trackers: [(ADBServerID, any DeviceTracking)] = [(.local, localTracker)]
      + profiles.filter(\.isEnabled).map { (.remote($0.id), ADBServerConnection.tracker(for: $0)) }
    let remoteServerLabels = Dictionary(uniqueKeysWithValues: profiles.map { (ADBServerID.remote($0.id), $0.connection.displayAddress) })
    let adbService = ADBService(trackers: trackers)
    let deviceTracker = adbService
    let deviceManager = DeviceManager(
      adb: adbService, deviceTracker: deviceTracker, client: hostClient, remoteServerLabels: remoteServerLabels
    )
    let adbServers = ADBServers(
      service: adbService, store: serverStore, profiles: profiles, error: serverError,
      makeTracker: ADBServerConnection.tracker
    ) { deviceManager.updateRemoteServerLabels($0) }
    deviceManager.linkServers = { [weak adbServers] in adbServers?.deviceLinkServers ?? [:] }
    self.adbServers = adbServers
    let captureHistory = CaptureHistory()
    let recordFrame: @MainActor @Sendable (CaptureMedia) -> Void = { captureHistory.recordFrame($0) }
    let fileStore = FileStore(frameExportHandler: recordFrame)
    let captureCoordinator = CaptureCoordinator()
    let startRecording: RecordingCapture.StartRecording = { device, bugReport in
      let target = try device.requireConnection()
      if device.isLocalEmulator || bugReport {
        let session = try await adbService.exec().bound(to: target).startScreenrecord(deviceID: device.serial, bugReport: bugReport)
        return ADBScreenRecording(session: session, adb: adbService)
      }
      return try await NativeScreenRecording.start(target: target)
    }
    let screenshots = ScreenshotService(adb: adbService, fileStore: fileStore)
    let timestamps = CaptureTimestampSource()
    let livePreview = LivePreviewService(coordinator: captureCoordinator, adb: adbService, settings: .shared)

    self.deviceManager = deviceManager
    self.adbService = adbService
    self.deviceTracker = deviceTracker
    self.fileStore = fileStore
    self.captureHistory = captureHistory
    self.captureCoordinator = captureCoordinator
    self.livePreview = livePreview
    let makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController? = {
      EmulatorControlsController.live(target: $0)
    }
    let captureServices = CaptureServices(
      livePreview: livePreview,
      screenshots: { device in
        ScreenshotCapture(
          device: device, screenshots: screenshots, fileStore: fileStore,
          coordinator: captureCoordinator
        )
      },
      recording: { device, options in
        RecordingCapture(
          device: device, options: options, adb: adbService, fileStore: fileStore,
          coordinator: captureCoordinator,
          startRecording: startRecording, loadRecording: nil, timestampSource: timestamps
        )
      },
      makeEmulatorControls: makeEmulatorControls
    )
    startupDiscovery = StartupCaptureDiscovery(tracker: deviceTracker, manager: deviceManager, preparation: captureServices.startup)
    workspaces = CaptureWorkspaces(
      captureServices: captureServices, deviceManager: deviceManager, fileStore: fileStore, adbService: adbService,
      history: captureHistory
    ) { adbServers.configuredServerIDs }
  }

  func start() {
    guard !hasStarted, shutdownTask == nil else { return }
    hasStarted = true

    Perf.step(.appFirstSnapshot, "services start")
    startupDiscovery.start()
    adbServers.start()
    deviceManager.start()
    captureHistory.start()
  }

  func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }

    adbServers.beginShutdown()
    pendingCleanup = Set(Cleanup.allCases)
    captureCoordinator.beginShutdown()
    fileStore.beginShutdown()
    let workspaceCleanup = workspaces.beginShutdown()
    let deviceCleanup = deviceManager.shutdown()
    let startupCleanup = startupDiscovery.beginShutdown()
    let deviceTracker = deviceTracker
    let captureCoordinator = captureCoordinator
    let livePreview = livePreview
    let captureHistory = captureHistory
    let fileStore = fileStore
    let task = Task {
      Perf.start(.appShutdown, name: "App Quit → Cleanup")
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await startupCleanup.value
          await self.finishCleanup(.startup)
          Perf.step(.appShutdown, "startup preparation discarded")
        }
        group.addTask {
          await workspaceCleanup.value
          await self.finishCleanup(.workspaces)
          Perf.step(.appShutdown, "workspaces closed")
        }
        group.addTask {
          await deviceCleanup.value
          await self.finishCleanup(.deviceManager)
        }
        group.addTask {
          await livePreview.shutdown()
          await self.finishCleanup(.livePreview)
          Perf.step(.appShutdown, "live preview stopped")
        }
      }
      await captureCoordinator.waitUntilIdle()
      finishCleanup(.reservations)
      // Keep device connections open until captures and previews have restored their settings.
      await adbServers.stop()
      await deviceTracker.stopTracking()
      finishCleanup(.deviceTracker)
      Perf.step(.appShutdown, "device tracking stopped")
      await fileStore.shutdown()
      finishCleanup(.files)
      Perf.step(.appShutdown, "file exports finished")
      await captureHistory.shutdown()
      finishCleanup(.history)
      Perf.step(.appShutdown, "history exports finished")
      Perf.end(.appShutdown, finalLabel: "cleanup finished")
    }
    shutdownTask = task
    await task.value
  }

  private func finishCleanup(_ owner: Cleanup) {
    pendingCleanup.remove(owner)
  }
}

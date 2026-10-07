import Foundation
import Observation

/// Starts shared services and waits for them to stop when the app quits.
@MainActor
final class AppRuntime {
  let deviceManager: DeviceManager
  let adbService: ADBService
  let adbServers: ADBServers
  private let deviceTracker: any DeviceTracking
  let fileStore: FileStore
  private let captureServices: CaptureServices
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

  private var startupTask: Task<Void, Never>?
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
      + profiles.map { (.remote($0.id), ADBServerConnection.tracker(for: $0)) }
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
    let makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController? = {
      EmulatorControlsController.live(target: $0)
    }
    let captureServices = CaptureServices(
      livePreview: livePreview,
      screenshots: { devices in
        ScreenshotCapture(
          devices: devices, screenshots: screenshots, fileStore: fileStore,
          coordinator: captureCoordinator
        )
      },
      recording: { devices, options in
        RecordingCapture(
          devices: devices, options: options, adb: adbService, fileStore: fileStore,
          coordinator: captureCoordinator,
          startRecording: startRecording, loadRecording: nil, timestampSource: timestamps
        )
      },
      makeEmulatorControls: makeEmulatorControls
    )
    self.captureServices = captureServices
    workspaces = CaptureWorkspaces(
      captureServices: captureServices, deviceManager: deviceManager, fileStore: fileStore, adbService: adbService,
      history: captureHistory
    ) { adbServers.configuredServerIDs }
  }

  func start() {
    guard startupTask == nil, shutdownTask == nil else { return }

    Perf.step(.appFirstSnapshot, "services start")
    adbServers.start()
    deviceManager.start()
    let manager = deviceManager
    startupTask = Task.immediate { [weak self] in
      #if PERF_TRACING
      Perf.startupEvent("runtime startup task entered")
      #endif
      let settings = AppSettings.shared
      let updates = Observations {
        (
          settings.startupCaptureMode, settings.lastViewedDeviceID,
          manager.inventory, manager.isShuttingDown
        )
      }
      for await (mode, preferredID, inventory, isShuttingDown) in updates {
        guard !Task.isCancelled, !isShuttingDown, let self, captureServices.startup.isAvailable else { return }
        let devices: [Device]
        switch mode {
        case .livePreview:
          let connected = inventory.connected ?? []
          let preferred = connected.first { $0.id == preferredID } ?? connected.first
          devices = preferred.map { [$0] } ?? []
        case .screenshot:
          devices = inventory.ready ?? []
        }
        captureServices.startup.prepare(mode: mode, devices: devices)
      }
    }
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
    let activeStartupTask = startupTask
    activeStartupTask?.cancel()
    startupTask = nil
    let deviceTracker = deviceTracker
    let captureCoordinator = captureCoordinator
    let captureServices = captureServices
    let captureHistory = captureHistory
    let fileStore = fileStore
    let task = Task {
      Perf.start(.appShutdown, name: "App Quit → Cleanup")
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await activeStartupTask?.value
          await captureServices.startup.discard()
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
          await captureServices.livePreview.shutdown()
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

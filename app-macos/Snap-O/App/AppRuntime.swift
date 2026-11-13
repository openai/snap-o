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
  private var startupDevices: [Device] = []
  private var discoveryTask: Task<Void, Never>?
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
    self.captureServices = captureServices
    workspaces = CaptureWorkspaces(
      captureServices: captureServices, deviceManager: deviceManager, fileStore: fileStore, adbService: adbService,
      history: captureHistory
    ) { adbServers.configuredServerIDs }
  }

  func start() {
    guard startupTask == nil, shutdownTask == nil else { return }

    Perf.step(.appFirstSnapshot, "services start")
    let manager = deviceManager
    let startup = captureServices.startup
    let tracker = deviceTracker
    let settings = AppSettings.shared
    let initialMode = settings.startupCaptureMode
    let initialID = settings.lastViewedDeviceID
    // Start device capture while SwiftUI is busy building the first window.
    discoveryTask = Task(priority: .userInitiated) { @concurrent [weak self] in
      await tracker.startTracking()
      var firstInventory = true
      for await devices in await tracker.previewDeviceStream() {
        guard !Task.isCancelled else { return }
        let selected = Self.preferredDevice(in: devices, id: initialID)
        let discovered = firstInventory && initialMode == .livePreview ? selected?.connection.flatMap(DiscoveredVideo.init) : nil
        firstInventory = false
        let used = await self?.prepareDiscovery(devices, video: discovered)
        if used != true { await discovered?.close() }
        guard used != nil else { return }
      }
    }
    startupTask = Task.immediate { [weak self] in
      #if PERF_TRACING
      Perf.startupEvent("runtime startup task entered")
      #endif
      let updates = Observations {
        (settings.startupCaptureMode, settings.lastViewedDeviceID, manager.inventory.ready, manager.isShuttingDown)
      }
      for await (_, _, _, isShuttingDown) in updates {
        guard !Task.isCancelled, !isShuttingDown, startup.isAvailable else { return }
        self?.prepareStartup()
      }
    }
    adbServers.start()
    deviceManager.start()
    captureHistory.start()
  }

  private nonisolated static func preferredDevice(in devices: [Device], id: String?) -> Device? {
    devices.first { $0.id == id } ?? devices.first
  }

  private func prepareDiscovery(_ devices: [Device], video: DiscoveredVideo?) -> Bool? {
    guard !Task.isCancelled, !deviceManager.isShuttingDown, captureServices.startup.isAvailable else { return nil }
    startupDevices = devices
    return prepareStartup(video: video)
  }

  @discardableResult
  private func prepareStartup(video: DiscoveredVideo? = nil) -> Bool {
    let settings = AppSettings.shared
    let preferred = Self.preferredDevice(in: startupDevices, id: settings.lastViewedDeviceID)
    let device: Device? = switch settings.startupCaptureMode {
    case .livePreview: preferred
    case .screenshot: deviceManager.inventory.ready?.first { $0.id == preferred?.id && $0.connection == preferred?.connection }
    }
    let discovered = settings.startupCaptureMode == .livePreview && video?.target == device?.connection ? video : nil
    return captureServices.startup.prepare(mode: settings.startupCaptureMode, device: device, discovered: discovered)
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
    let activeDiscovery = discoveryTask
    activeDiscovery?.cancel()
    discoveryTask = nil
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
          await activeDiscovery?.value
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

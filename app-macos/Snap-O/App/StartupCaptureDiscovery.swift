import Observation

/// Uses ADB discovery and capture settings to prepare the first capture.
@MainActor
final class StartupCaptureDiscovery {
  private let tracker: any DeviceTracking
  private let manager: DeviceManager
  private let preparation: StartupCapturePreparation
  private let settings = AppSettings.shared
  private var connectedDevices: [Device] = []
  private var discoveryTask: Task<Void, Never>?
  private var settingsTask: Task<Void, Never>?

  init(tracker: any DeviceTracking, manager: DeviceManager, preparation: StartupCapturePreparation) {
    self.tracker = tracker
    self.manager = manager
    self.preparation = preparation
  }

  func start() {
    let initialID = settings.lastViewedDeviceID
    let startsWithPreview = settings.startupCaptureMode == .livePreview
    // Start device capture while SwiftUI is busy building the first window.
    discoveryTask = Task(priority: .userInitiated) { @concurrent [weak self, tracker] in
      await tracker.startTracking()
      var canStartEarly = startsWithPreview
      for await devices in await tracker.previewDeviceStream() {
        guard !Task.isCancelled else { return }
        // An empty inventory from one ADB server can arrive before another finds the phone.
        let video: DiscoveredVideo? = if canStartEarly,
                                         let target = try? Self.preferredDevice(in: devices, id: initialID)?.requireConnection() {
          DiscoveredVideo(target: target)
        } else {
          nil
        }
        if video != nil { canStartEarly = false }
        let adopted = await self?.prepareDiscoveredDevices(devices, video: video)
        if adopted != true { await video?.close() }
        guard adopted != nil else { return }
      }
    }
    settingsTask = Task.immediate { [weak self, settings, manager] in
      #if PERF_TRACING
      Perf.startupEvent("runtime startup task entered")
      #endif
      let updates = Observations {
        (settings.startupCaptureMode, settings.lastViewedDeviceID, manager.inventory.ready, manager.isShuttingDown)
      }
      for await (_, _, _, isShuttingDown) in updates {
        guard !Task.isCancelled, !isShuttingDown, let self, preparation.isAvailable else { return }
        prepare()
      }
    }
  }

  func beginShutdown() -> Task<Void, Never> {
    discoveryTask?.cancel()
    settingsTask?.cancel()
    let cleanup = Task { [discoveryTask, settingsTask, preparation] in
      await settingsTask?.value
      await discoveryTask?.value
      await preparation.discard()
    }
    discoveryTask = nil
    settingsTask = nil
    return cleanup
  }

  private nonisolated static func preferredDevice(in devices: [Device], id: String?) -> Device? {
    devices.first { $0.id == id } ?? devices.first
  }

  /// Returns nil when startup has ended and false when preparation did not adopt the stream.
  private func prepareDiscoveredDevices(_ devices: [Device], video: DiscoveredVideo?) -> Bool? {
    guard !Task.isCancelled, !manager.isShuttingDown, preparation.isAvailable else { return nil }
    connectedDevices = devices
    return prepare(video: video)
  }

  @discardableResult
  private func prepare(video: DiscoveredVideo? = nil) -> Bool {
    let preferred = Self.preferredDevice(in: connectedDevices, id: settings.lastViewedDeviceID)
    let mode = settings.startupCaptureMode
    let device: Device? = switch mode {
    case .livePreview: preferred
    case .screenshot: manager.inventory.ready?.first { $0.id == preferred?.id && $0.connection == preferred?.connection }
    }
    let discovered = mode == .livePreview && video?.target == device?.connection ? video : nil
    return preparation.prepare(mode: mode, device: device, discovered: discovered)
  }
}

import Foundation
import Observation

/// App-scoped services and their startup lifecycle.
@MainActor
final class AppRuntime {
  let deviceManager: DeviceManager
  let adbService: ADBService
  let deviceTracker: DeviceTracker
  let fileStore: FileStore
  let captureServices: CaptureServices
  let captureHistory: CaptureHistory

  private let captureCoordinator: CaptureCoordinator

  private var startupTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  private var startupDevices: [Device] = []

  init() {
    let adbService = ADBService()
    let deviceTracker = DeviceTracker(adbService: adbService)
    let captureHistory = CaptureHistory()
    let fileStore = FileStore { url, deviceID, size in
      captureHistory.recordFrame(url: url, size: size) {
        await deviceTracker.latestDevices.first { $0.id == deviceID }
          ?? Device(id: deviceID, model: deviceID, androidVersion: "", vendorModel: nil, manufacturer: nil, avdName: nil)
      }
    }
    let captureCoordinator = CaptureCoordinator()
    let screenshots = ScreenshotService(adb: adbService, fileStore: fileStore, history: captureHistory.repository)
    let recording = RecordingService(
      adb: adbService,
      fileStore: fileStore,
      coordinator: captureCoordinator,
      history: captureHistory.repository
    )
    let livePreview = LivePreviewService(
      adb: adbService,
      coordinator: captureCoordinator
    )

    deviceManager = DeviceManager(adb: adbService, deviceTracker: deviceTracker)
    self.adbService = adbService
    self.deviceTracker = deviceTracker
    self.fileStore = fileStore
    self.captureHistory = captureHistory
    self.captureCoordinator = captureCoordinator
    captureServices = CaptureServices(
      screenshots: screenshots,
      recording: recording,
      livePreview: livePreview,
      startup: StartupCapturePreparation(screenshots: screenshots, livePreview: livePreview)
    )
  }

  func start() {
    guard startupTask == nil, shutdownTask == nil else { return }

    Perf.step(.appFirstSnapshot, "services start")
    let tracker = deviceTracker
    let discovery = Task.detached(priority: .userInitiated) { await tracker.startTracking() }
    if AppSettings.shared.startupCaptureMode == .livePreview {
      let preferredID = AppSettings.shared.lastViewedDeviceID
      captureServices.startup.prepareEarlyPreview(
        options: LivePreviewOptions(showsTouches: AppSettings.shared.showTouchesDuringCapture)
      ) {
        await discovery.value
        let stream = await tracker.previewDeviceStream()
        for await devices in stream {
          guard !Task.isCancelled else { return nil }
          if let preferredID, devices.contains(where: { $0.id == preferredID }) { return preferredID }
          if let first = devices.first { return first.id }
        }
        return nil
      }
    }
    captureHistory.start()
    observeStartupSettings()

    let deviceTracker = deviceTracker
    startupTask = Task { [weak self] in
      #if PERF_TRACING
      Perf.startupEvent("runtime startup task entered")
      #endif
      await discovery.value
      let stream = await deviceTracker.deviceStream()
      for await devices in stream {
        guard !Task.isCancelled, let self, captureServices.startup.isAvailable else { return }
        startupDevices = devices
        refreshStartupPreparation()
      }
    }
  }

  private func refreshStartupPreparation() {
    guard shutdownTask == nil else { return }
    captureServices.startup.prepare(
      mode: AppSettings.shared.startupCaptureMode,
      devices: startupDevices,
      liveOptions: LivePreviewOptions(showsTouches: AppSettings.shared.showTouchesDuringCapture)
    )
  }

  private func observeStartupSettings() {
    guard shutdownTask == nil, captureServices.startup.isAvailable else { return }
    withObservationTracking {
      _ = AppSettings.shared.startupCaptureMode
      _ = AppSettings.shared.showTouchesDuringCapture
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.refreshStartupPreparation()
        self?.observeStartupSettings()
      }
    }
  }

  func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }

    deviceManager.shutdown()
    let activeStartupTask = startupTask
    activeStartupTask?.cancel()
    startupTask = nil
    let deviceTracker = deviceTracker
    let captureCoordinator = captureCoordinator
    let captureServices = captureServices
    let task = Task {
      Perf.start(.appShutdown, name: "App Quit → Cleanup")
      await captureCoordinator.beginShutdown()
      await captureServices.startup.discard()
      Perf.step(.appShutdown, "startup preparation discarded")
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await activeStartupTask?.value
          await deviceTracker.stopTracking()
          Perf.step(.appShutdown, "device tracking stopped")
        }
        group.addTask {
          await captureServices.screenshots.shutdown()
          Perf.step(.appShutdown, "screenshots stopped")
        }
        group.addTask {
          await captureServices.recording.shutdown()
          Perf.step(.appShutdown, "recording stopped")
        }
        group.addTask {
          await captureServices.livePreview.shutdown()
          Perf.step(.appShutdown, "live preview stopped")
        }
      }
      await captureCoordinator.waitUntilIdle()
      Perf.end(.appShutdown, finalLabel: "cleanup finished")
    }
    shutdownTask = task
    await task.value
    await captureHistory.finishFrameExports()
    captureHistory.stop()
  }
}

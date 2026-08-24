import Foundation
import Observation
import SnapODeviceClient

/// App-scoped services and their startup lifecycle.
@MainActor
final class AppRuntime {
  let adbService: ADBService
  let deviceTracker: DeviceTracker
  let fileStore: FileStore
  let captureServices: CaptureServices

  private let captureCoordinator: CaptureCoordinator

  private var startupTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  private var startupDevices: [Device] = []

  init() {
    let adbService = ADBService()
    let deviceTracker = DeviceTracker(adbService: adbService)
    let fileStore = FileStore()
    let captureCoordinator = CaptureCoordinator()
    let screenshots = ScreenshotService(adb: adbService, fileStore: fileStore)
    let recording = RecordingService(
      adb: adbService,
      fileStore: fileStore,
      coordinator: captureCoordinator
    )
    let livePreview = LivePreviewService(
      adb: adbService,
      coordinator: captureCoordinator
    )

    self.adbService = adbService
    self.deviceTracker = deviceTracker
    self.fileStore = fileStore
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
    observeStartupSettings()

    let deviceTracker = deviceTracker
    startupTask = Task { [weak self] in
      await deviceTracker.startTracking()
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
  }
}

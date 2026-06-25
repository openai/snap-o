import Foundation

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
      livePreview: livePreview
    )
  }

  func start() {
    guard startupTask == nil, shutdownTask == nil else { return }

    Perf.step(.appFirstSnapshot, "services start")

    let deviceTracker = deviceTracker
    let screenshots = captureServices.screenshots
    startupTask = Task {
      await deviceTracker.startTracking()
      guard !Task.isCancelled else { return }
      Perf.step(.appFirstSnapshot, "start preload task")
      let stream = await deviceTracker.deviceStream()
      Perf.step(.appFirstSnapshot, "query device stream")
      for await devices in stream where !devices.isEmpty {
        guard !Task.isCancelled else { return }
        await screenshots.preload(for: devices)
        break
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
      await captureCoordinator.beginShutdown()
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await activeStartupTask?.value
          await deviceTracker.stopTracking()
        }
        group.addTask {
          await captureServices.screenshots.shutdown()
        }
        group.addTask {
          await captureServices.recording.shutdown()
        }
        group.addTask {
          await captureServices.livePreview.shutdown()
        }
      }
      await captureCoordinator.waitUntilIdle()
    }
    shutdownTask = task
    await task.value
  }
}

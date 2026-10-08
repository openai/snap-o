import Foundation
import Observation

@Observable
@MainActor
final class ScreenshotCapture: CaptureOperation {
  let id = UUID()
  let device: Device
  let kind: CaptureKind = .screenshot
  private(set) var state: CaptureState = .pending
  private(set) var isComplete = false
  private let screenshots: ScreenshotService
  private let fileStore: FileStore
  private let coordinator: CaptureCoordinator?
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(
    device: Device, screenshots: ScreenshotService, fileStore: FileStore,
    coordinator: CaptureCoordinator? = nil
  ) {
    self.device = device
    self.fileStore = fileStore
    self.screenshots = screenshots
    self.coordinator = coordinator
  }

  func start() {
    guard work == nil, closeTask == nil else { return }
    work = Task {
      await capture()
      isComplete = true
    }
  }

  func waitForCompletion() async {
    await work?.value
  }

  func close() async {
    if let closeTask { await closeTask.value
      return
    }
    work?.cancel()
    let task = Task {
      await work?.value
      if work == nil { state = .cancelled }
      isComplete = true
      if let media { fileStore.discardPreviews([media]) }
    }
    closeTask = task
    await task.value
  }

  private func capture() async {
    var lease: DeviceCaptureLease?
    defer { if let lease { coordinator?.release(lease) } }
    do {
      try Task.checkCancellation()
      let target = try device.requireConnection()
      lease = try coordinator?.acquire(target: target, for: .screenshot)
      state = try await .ready(screenshots.capture(device: device))
    } catch {
      state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
    }
  }
}

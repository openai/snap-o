import CoreGraphics
import Foundation
import SnapODeviceClient

actor ScreenshotService {
  private struct Request {
    let index: Int
    let device: Device
  }

  private struct Outcome {
    let index: Int
    let device: Device
    let result: Result<CaptureMedia, Error>
  }

  private static let timeoutSeconds = 10

  private let adb: ADBService
  private let fileStore: FileStore
  private let timestampSource = CaptureTimestampSource()

  private var activeTasks: [UUID: Task<ScreenshotCaptureResult, Never>] = [:]
  private var preloadedTask: Task<ScreenshotCaptureResult, Never>?
  private var didStartPreload = false
  private var isShuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(adb: ADBService, fileStore: FileStore) {
    self.adb = adb
    self.fileStore = fileStore
  }

  func capture(for devices: [Device]) async -> ScreenshotCaptureResult {
    guard !isShuttingDown else { return Self.emptyResult }

    let requests = devices.enumerated().map { index, device in
      Request(
        index: index,
        device: device
      )
    }
    let taskID = UUID()
    let adb = adb
    let fileStore = fileStore
    let timestampSource = timestampSource
    let task = Task {
      await Self.capture(
        requests: requests,
        adb: adb,
        fileStore: fileStore,
        timestampSource: timestampSource
      )
    }
    activeTasks[taskID] = task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    activeTasks.removeValue(forKey: taskID)
    return result
  }

  func preload(for devices: [Device]) {
    guard !isShuttingDown, !didStartPreload, !devices.isEmpty else { return }

    Perf.step(.appFirstSnapshot, "Preloading first screenshot")
    didStartPreload = true
    preloadedTask = Task { [weak self] in
      guard let self else { return Self.emptyResult }
      return await capture(for: devices)
    }
  }

  func consumePreloaded() async -> [CaptureMedia] {
    guard let task = preloadedTask else { return [] }
    preloadedTask = nil
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    guard !Task.isCancelled else { return [] }
    let fresh = result.media.filter { Date().timeIntervalSince($0.media.capturedAt) <= 1 }
    guard !fresh.isEmpty else { return [] }
    Perf.step(.appFirstSnapshot, "return media")
    return fresh
  }

  func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }

    isShuttingDown = true
    let task = Task { await performShutdown() }
    shutdownTask = task
    await task.value
  }

  private func performShutdown() async {
    let preloadTask = preloadedTask
    preloadedTask = nil
    preloadTask?.cancel()

    let tasks = Array(activeTasks.values)
    for task in tasks {
      task.cancel()
    }
    _ = await preloadTask?.value
    for task in tasks {
      _ = await task.value
    }
    activeTasks.removeAll()
  }

  private static func capture(
    requests: [Request],
    adb: ADBService,
    fileStore: FileStore,
    timestampSource: CaptureTimestampSource
  ) async -> ScreenshotCaptureResult {
    var outcomes: [Outcome] = []
    await withTaskGroup(of: Outcome.self) { group in
      for request in requests {
        group.addTask {
          do {
            let media = try await captureWithTimeout(
              request: request,
              adb: adb,
              fileStore: fileStore,
              timestampSource: timestampSource
            )
            return Outcome(
              index: request.index,
              device: request.device,
              result: .success(media)
            )
          } catch {
            return Outcome(
              index: request.index,
              device: request.device,
              result: .failure(error)
            )
          }
        }
      }

      for await outcome in group {
        outcomes.append(outcome)
      }
    }

    var media: [CaptureMedia] = []
    var failures: [CaptureFailure] = []
    for outcome in outcomes.sorted(by: { $0.index < $1.index }) {
      switch outcome.result {
      case .success(let capture):
        media.append(capture)
      case .failure(let error):
        failures.append(CaptureFailure(device: outcome.device, error: error))
      }
    }
    return ScreenshotCaptureResult(media: media, failures: failures)
  }

  private static func captureWithTimeout(
    request: Request,
    adb: ADBService,
    fileStore: FileStore,
    timestampSource: CaptureTimestampSource
  ) async throws -> CaptureMedia {
    try await withThrowingTaskGroup(of: CaptureMedia.self) { group in
      group.addTask {
        try await capture(
          request: request,
          adb: adb,
          fileStore: fileStore,
          timestampSource: timestampSource
        )
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw ADBError.requestTimedOut(
          "Screenshot capture timed out after \(timeoutSeconds) seconds"
        )
      }

      defer { group.cancelAll() }
      guard let capture = try await group.next() else { throw CancellationError() }
      return capture
    }
  }

  private static func capture(
    request: Request,
    adb: ADBService,
    fileStore: FileStore,
    timestampSource: CaptureTimestampSource
  ) async throws -> CaptureMedia {
    let exec = await adb.exec()
    async let dataTask = exec.screencapPNG(deviceID: request.device.id)
    async let densityTask = try? await exec.displayDensity(deviceID: request.device.id)
    let data = try await dataTask
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(
      deviceID: request.device.id,
      capturedAt: capturedAt,
      kind: .image
    )
    let writeTask = Task(priority: .userInitiated) { () throws -> CGSize in
      try data.write(to: destination, options: [.atomic])
      return try pngSize(from: data)
    }

    let size = try await writeTask.value
    let densityValue = await densityTask
    let density = densityValue.map { CGFloat($0) }
    return CaptureMedia(
      device: request.device,
      media: .image(
        url: destination,
        capturedAt: capturedAt,
        display: DisplayInfo(size: size, densityScale: density)
      )
    )
  }

  private static var emptyResult: ScreenshotCaptureResult {
    ScreenshotCaptureResult(media: [], failures: [])
  }
}

import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class RecordingMode {
  enum Result {
    case completed(media: [CaptureMedia], error: Error?)
    case failed(Error)
  }

  private let recordingService: RecordingService
  private let initialDevices: [Device]
  private let options: RecordingOptions
  private let onResult: @MainActor (Result) -> Void
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var completionTask: Task<Void, Never>?
  private var operation: RecordingOperationHandle?
  private var connectedDeviceIDs: Set<String>
  private var hasCompleted = false

  init(
    recordingService: RecordingService,
    devices: [Device],
    options: RecordingOptions,
    onResult: @escaping @MainActor (Result) -> Void
  ) {
    self.recordingService = recordingService
    initialDevices = devices
    self.options = options
    self.onResult = onResult
    connectedDeviceIDs = Set(devices.map(\.id))
  }

  func start() {
    guard startTask == nil else { return }
    startTask = Task { [weak self] in
      guard let self else { return }
      do {
        let operation = try await recordingService.start(
          for: initialDevices,
          options: options
        )
        if hasCompleted {
          await recordingService.cancel(operation)
        } else {
          self.operation = operation
          observeCompletion(of: operation)
          await recordingService.updateConnectedDeviceIDs(
            connectedDeviceIDs,
            for: operation
          )
        }
      } catch {
        guard !hasCompleted else { return }
        hasCompleted = true
        onResult(.failed(error))
      }
    }
  }

  func updateDevices(_ devices: [Device]) async {
    connectedDeviceIDs = Set(devices.map(\.id))
    guard let operation, !hasCompleted else { return }
    await recordingService.updateConnectedDeviceIDs(
      connectedDeviceIDs,
      for: operation
    )
  }

  func finish() async {
    await startTask?.value
    guard !hasCompleted else { return }
    guard let operation else { return }
    await recordingService.finish(operation)
    await completionTask?.value
  }

  func cancel() async {
    await startTask?.value
    guard !hasCompleted else {
      await completionTask?.value
      return
    }
    hasCompleted = true
    guard let operation else { return }
    self.operation = nil
    await recordingService.cancel(operation)
    await completionTask?.value
  }

  private func observeCompletion(of operation: RecordingOperationHandle) {
    completionTask = Task { [weak self] in
      guard let self else { return }
      guard let result = await recordingService.waitForCompletion(of: operation) else { return }
      guard !hasCompleted else { return }
      hasCompleted = true
      self.operation = nil
      onResult(.completed(media: result.media, error: result.error))
    }
  }
}

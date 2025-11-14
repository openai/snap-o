import Foundation
import Observation

@Observable
@MainActor
final class RecordingMode {
  enum Result {
    case completed(media: [CaptureMedia], error: Error?)
    case failed(Error)
  }

  private let captureService: CaptureService
  private let initialDevices: [Device]
  private let onResult: @MainActor (Result) -> Void
  @ObservationIgnored private var startTask: Task<Void, Never>?
  private var sessions: [String: RecordingSession]?
  private var hasCompleted = false

  init(
    captureService: CaptureService,
    devices: [Device],
    onResult: @escaping @MainActor (Result) -> Void
  ) {
    self.captureService = captureService
    self.initialDevices = devices
    self.onResult = onResult
  }

  func start() {
    startTask = Task { [weak self] in
      guard let self else { return }
      let (sessions, encounteredError) = await self.captureService.startRecordings(for: self.initialDevices)
      if let error = encounteredError {
        self.hasCompleted = true
        self.onResult(.failed(error))
      } else {
        self.sessions = sessions
      }
    }
  }

  func finish(using devices: [Device]) async {
    await startTask?.value
    guard !hasCompleted else { return }
    guard let sessions else { return }
    hasCompleted = true
    let (media, encounteredError) = await captureService.stopRecordings(for: devices, sessions: sessions)
    onResult(.completed(media: media, error: encounteredError))
  }

  func cancel() {
    startTask?.cancel()
  }
}

@preconcurrency import AVFoundation
import Foundation

/// Writes the encoder's original samples; preview rendering never owns this subscription.
@MainActor
final class NativeScreenRecording: ScreenRecording {
  nonisolated let id = UUID()
  private let source: DeviceVideoSource
  private let url: URL
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var format: CMVideoFormatDescription?
  private var lastTimestamp: CMTime?
  private var lastReceivedAt: TimeInterval?
  private var finishTask: Task<Void, Error>?
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  init(deviceID: String) {
    source = DeviceVideoSource(deviceID: deviceID)
    url = FileManager.default.temporaryDirectory.appendingPathComponent("snapo-recording-\(id).mp4")
  }

  static func start(deviceID: String) async throws -> NativeScreenRecording {
    let recording = NativeScreenRecording(deviceID: deviceID)
    recording.source.start { [weak recording] event in
      recording?.receive(event)
    }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(8))
      while recording.writer == nil {
        if recording.finishTask != nil { try await recording.waitUntilStopped() }
        guard ContinuousClock.now < deadline else { throw ADBError.requestTimedOut("Recording did not receive a video frame") }
        try await Task.sleep(for: .milliseconds(10))
      }
      if recording.finishTask != nil { try await recording.waitUntilStopped() }
      return recording
    } catch {
      await recording.remove()
      throw error
    }
  }

  func waitUntilStopped() async throws {
    if finishTask == nil {
      await withCheckedContinuation { stopWaiters.append($0) }
    }
    try await finishTask?.value
  }

  func stop() async throws {
    beginFinish(error: nil)
    try await waitUntilStopped()
  }

  func save(to destination: URL) async throws {
    _ = await finishTask?.result
    guard writer?.status == .completed else { throw writer?.error ?? ADBError.protocolFailure("No playable recording was received") }
    try FileManager.default.copyItem(at: url, to: destination)
  }

  func remove() async {
    await close()
    try? FileManager.default.removeItem(at: url)
  }

  func close() async {
    try? await stop()
  }

  func receive(_ event: LivePreviewFrameEvent) {
    guard finishTask == nil else { return }
    do {
      switch event {
      case .format(let incoming):
        if let format, writer != nil, !CMFormatDescriptionEqual(format, otherFormatDescription: incoming) {
          throw ADBError.protocolFailure("Recording ended because the device video format changed")
        }
        format = incoming
      case .sample(let sample, let keyFrame):
        if writer == nil {
          guard keyFrame, let format else { return }
          try begin(sample: sample, format: format)
        }
        guard let input, let writer else { return }
        guard input.isReadyForMoreMediaData else { throw ADBError.protocolFailure("Recording storage could not keep up with the device") }
        guard input.append(sample) else { throw writer.error ?? ADBError.protocolFailure("Could not write video frame") }
        lastTimestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        lastReceivedAt = ProcessInfo.processInfo.systemUptime
      case .stopped(let error):
        beginFinish(error: error ?? ADBError.protocolFailure("Device video ended unexpectedly"))
      }
    } catch {
      beginFinish(error: error)
    }
  }

  private func begin(sample: CMSampleBuffer, format: CMVideoFormatDescription) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw ADBError.protocolFailure("Unsupported recording format") }
    writer.add(input)
    writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    guard writer.startWriting() else { throw writer.error ?? ADBError.protocolFailure("Could not start recording") }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
    writer.startSession(atSourceTime: timestamp)
    self.writer = writer
    self.input = input
  }

  private func beginFinish(error: Error?) {
    guard finishTask == nil else { return }
    source.stop()
    finishTask = Task {
      if let writer, let input {
        if let lastTimestamp, let lastReceivedAt {
          let tail = max(1.0 / 60, ProcessInfo.processInfo.systemUptime - lastReceivedAt)
          writer.endSession(atSourceTime: lastTimestamp + CMTime(seconds: tail, preferredTimescale: 1_000_000))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ADBError.protocolFailure("Could not finalize recording") }
      }
      if let error { throw error }
    }
    for waiter in stopWaiters {
      waiter.resume()
    }
    stopWaiters.removeAll()
  }
}

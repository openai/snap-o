@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Records device samples; preview rendering never owns this subscription.
@MainActor
final class NativeScreenRecording: ScreenRecording {
  nonisolated let id = UUID()
  private let clock: AnyClock<Duration>
  private let source: any LivePreviewFrameSource
  private let url: URL
  private var writer: (any NativeRecordingWriter)?
  private let makeWriter: @MainActor (URL, CMVideoFormatDescription, CMTime) throws -> any NativeRecordingWriter
  private var format: CMVideoFormatDescription?
  private var lastTimestamp: CMTime?
  private var lastReceivedAt: AnyClock<Duration>.Instant?
  private var hasSavedCopy = false
  private var finishTask: Task<Void, Error>?
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  convenience init(target: DeviceTarget) {
    // An idle preview's cached timestamp can predate the start of recording.
    self.init(source: DeviceVideoSource(target: target, replaysLastFrame: false))
  }

  init(
    source: any LivePreviewFrameSource,
    makeWriter: @escaping @MainActor (URL, CMVideoFormatDescription, CMTime) throws -> any NativeRecordingWriter = AVRecordingWriter
      .init
  ) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.source = source
    self.makeWriter = makeWriter
    url = FileManager.default.temporaryDirectory.appendingPathComponent("snapo-recording-\(id).mp4")
  }

  static func start(target: DeviceTarget) async throws -> NativeScreenRecording {
    let recording = NativeScreenRecording(target: target)
    recording.source.start { [weak recording] event in
      recording?.receive(event)
    }
    do {
      let deadline = recording.clock.now.advanced(by: .seconds(8))
      while recording.writer == nil {
        if recording.finishTask != nil { try await recording.waitUntilStopped() }
        guard recording.clock.now < deadline else { throw ADBError.requestTimedOut("Recording did not receive a video frame") }
        try await recording.clock.sleep(for: .milliseconds(10))
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
    guard writer?.isComplete == true else { throw ADBError.protocolFailure("No playable recording was received") }
    try FileManager.default.copyItem(at: url, to: destination)
    hasSavedCopy = true
  }

  func remove() async {
    await close()
    try? FileManager.default.removeItem(at: url)
  }

  func close() async {
    try? await stop()
    if hasSavedCopy { try? FileManager.default.removeItem(at: url) }
  }

  func receive(_ event: LivePreviewFrameEvent) {
    guard finishTask == nil else { return }
    do {
      switch event {
      case .density: break
      case .format(let incoming, _):
        if let format, writer != nil, !CMFormatDescriptionEqual(format, otherFormatDescription: incoming) {
          throw ADBError.protocolFailure("Recording ended because the device video format changed")
        }
        format = incoming
      case .sample(let sample, let keyFrame):
        if writer == nil {
          guard keyFrame, let format else { return }
          try begin(sample: sample, format: format)
        }
        try writer?.append(sample)
        lastTimestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        lastReceivedAt = clock.now
      case .stopped(let error):
        beginFinish(error: error ?? ADBError.protocolFailure("Device video ended unexpectedly"))
      }
    } catch {
      beginFinish(error: error)
    }
  }

  private func begin(sample: CMSampleBuffer, format: CMVideoFormatDescription) throws {
    writer = try makeWriter(url, format, CMSampleBufferGetPresentationTimeStamp(sample))
  }

  private func beginFinish(error: Error?) {
    guard finishTask == nil else { return }
    source.stop()
    let stoppedAt = clock.now
    finishTask = Task {
      await source.waitUntilStopped()
      if let writer {
        var end: CMTime?
        if let lastTimestamp, let lastReceivedAt {
          let elapsed = lastReceivedAt.duration(to: stoppedAt).components
          let tail = max(1.0 / 60, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
          end = lastTimestamp + CMTime(seconds: tail, preferredTimescale: 1_000_000)
        }
        try await writer.finish(at: end)
      }
      if let error { throw error }
    }
    for waiter in stopWaiters {
      waiter.resume()
    }
    stopWaiters.removeAll()
  }
}

@MainActor
protocol NativeRecordingWriter: AnyObject {
  var isComplete: Bool { get }
  func append(_ sample: CMSampleBuffer) throws
  func finish(at end: CMTime?) async throws
}

@MainActor
final class AVRecordingWriter: NativeRecordingWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  var isComplete: Bool {
    writer.status == .completed
  }

  var isReadyForMoreMediaData: Bool {
    input.isReadyForMoreMediaData
  }

  init(url: URL, format: CMVideoFormatDescription, start: CMTime) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    var settings: [String: Any]?
    if CMFormatDescriptionGetMediaSubType(format) == kCVPixelFormatType_32BGRA {
      let size = CMVideoFormatDescriptionGetDimensions(format)
      settings = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
      ]
    }
    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: format)
    if settings != nil { input.mediaTimeScale = 1_000_000 }
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw ADBError.protocolFailure("Unsupported recording format") }
    writer.add(input)
    writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    guard writer.startWriting() else { throw writer.error ?? ADBError.protocolFailure("Could not start recording") }
    writer.startSession(atSourceTime: start)
  }

  func append(_ sample: CMSampleBuffer) throws {
    guard isReadyForMoreMediaData else { throw ADBError.protocolFailure("Recording storage could not keep up with the device") }
    guard input.append(sample) else { throw writer.error ?? ADBError.protocolFailure("Could not write video frame") }
  }

  func finish(at end: CMTime?) async throws {
    if let end { writer.endSession(atSourceTime: end) }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? ADBError.protocolFailure("Could not finalize recording") }
  }
}

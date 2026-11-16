@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Owns one recording's device subscriptions and output file.
@MainActor
final class NativeScreenRecording: ScreenRecording {
  nonisolated let id = UUID()
  private let clock: AnyClock<Duration>
  private let source: any LivePreviewFrameSource
  private let audioConnection: DeviceAudioConnection?
  private var videoTrack = RecordingVideoTrack()
  private let audioTrack: RecordingAudioTrack?
  private let url: URL
  private var writer: (any NativeRecordingWriter)?
  private let makeWriter: @MainActor (URL, CMVideoFormatDescription, CMTime, CMAudioFormatDescription?) throws -> any NativeRecordingWriter
  private var hasSavedCopy = false
  private var finishTask: Task<Void, Error>?
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  var captureWarning: String? {
    audioTrack?.captureWarning
  }

  init(
    source: any LivePreviewFrameSource,
    audioConnection: DeviceAudioConnection? = nil, audioTrack: RecordingAudioTrack? = nil,
    makeWriter: @escaping @MainActor (URL, CMVideoFormatDescription, CMTime, CMAudioFormatDescription?) throws -> any NativeRecordingWriter
      = AVRecordingWriter.init
  ) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.source = source
    self.audioConnection = audioConnection
    self.audioTrack = audioTrack
    self.makeWriter = makeWriter
    url = FileManager.default.temporaryDirectory.appendingPathComponent("snapo-recording-\(id).mp4")
  }

  static func start(target: DeviceTarget, recordsDeviceAudio: Bool, recordsMicrophone: Bool) async throws -> NativeScreenRecording {
    let audioConnection = DeviceHelper.AudioSource(playback: recordsDeviceAudio, microphone: recordsMicrophone).map { source in
      DeviceAudioConnection(target: target, source: source)
    }
    let audioTrack = audioConnection == nil ? nil : try RecordingAudioTrack()
    // An idle preview's cached timestamp can predate the start of recording.
    let recording = NativeScreenRecording(
      source: DeviceVideoSource(target: target, replaysLastFrame: false),
      audioConnection: audioConnection, audioTrack: audioTrack
    )
    do {
      if let audioConnection, let audioTrack {
        audioConnection.start { [weak recording] event in recording?.receiveAudioEvent(event) } failed: { [weak recording] error in
          recording?.beginFinish(error: error)
        }
        try await recording.waitForStartup("Recording did not receive device audio") { audioTrack.hasBufferedSamples }
      }
      recording.source.start { [weak recording] event in recording?.receive(event) }
      try await recording.waitForStartup("Recording did not receive a video frame") { recording.writer != nil }
      if let audioTrack {
        try await recording.waitForStartup("Recording did not receive device audio") { audioTrack.endTime != nil }
      }
      return recording
    } catch {
      await recording.remove()
      throw error
    }
  }

  private func waitForStartup(_ message: String, until ready: () -> Bool) async throws {
    let deadline = clock.now.advanced(by: .seconds(8))
    while !ready() {
      if finishTask != nil { try await waitUntilStopped() }
      guard clock.now < deadline else { throw ADBError.requestTimedOut(message) }
      try await clock.sleep(for: .milliseconds(10))
    }
    try Task.checkCancellation()
    if finishTask != nil { try await waitUntilStopped() }
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
      guard let (sample, format) = try videoTrack.sample(for: event) else { return }
      if let writer {
        try videoTrack.append(sample, to: writer, clock: clock)
      } else {
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        let writer = try makeWriter(url, format, start, audioTrack?.format)
        self.writer = writer
        audioTrack?.start(at: start, writer: writer)
        try videoTrack.append(sample, to: writer, clock: clock)
        try audioTrack?.appendBufferedSamples()
      }
    } catch {
      beginFinish(error: error)
    }
  }

  func receiveAudioEvent(_ event: DeviceAudioPacket.Event) {
    guard finishTask == nil else { return }
    do {
      try audioTrack?.receive(event)
    } catch {
      beginFinish(error: error)
    }
  }

  private func beginFinish(error: Error?) {
    guard finishTask == nil else { return }
    source.stop()
    audioConnection?.stop()
    let end = [videoTrack.endTime(at: clock.now), audioTrack?.endTime].compactMap(\.self).max()
    finishTask = Task {
      await source.waitUntilStopped()
      await audioConnection?.waitUntilStopped()
      try await writer?.finish(at: end)
      if let error { throw error }
    }
    for waiter in stopWaiters {
      waiter.resume()
    }
    stopWaiters.removeAll()
  }
}

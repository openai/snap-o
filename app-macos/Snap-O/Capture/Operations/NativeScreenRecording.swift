@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Owns one recording's device subscriptions and output file.
@MainActor
final class NativeScreenRecording: ScreenRecording {
  private let clock: AnyClock<Duration>
  private let source: any LivePreviewFrameSource
  private let audioConnection: DeviceAudioConnection?
  private let computerMicrophone: ComputerMicrophoneCapture?
  private var computerAudioTask: Task<Void, Error>?
  private var computerMicrophoneStopTime: CMTime?
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
    audioConnection: DeviceAudioConnection? = nil,
    computerMicrophone: ComputerMicrophoneCapture? = nil,
    audioTrack: RecordingAudioTrack? = nil,
    makeWriter: @escaping @MainActor (URL, CMVideoFormatDescription, CMTime, CMAudioFormatDescription?) throws -> any NativeRecordingWriter
      = AVRecordingWriter.init
  ) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.source = source
    self.audioConnection = audioConnection
    self.computerMicrophone = computerMicrophone
    self.audioTrack = audioTrack
    self.makeWriter = makeWriter
    url = FileManager.default.temporaryDirectory.appendingPathComponent("snapo-recording-\(UUID()).mp4")
  }

  static func start(
    source: any LivePreviewFrameSource, audioConnection: DeviceAudioConnection?, computerMicrophoneTarget: DeviceTarget?
  ) async throws -> NativeScreenRecording {
    let microphone = computerMicrophoneTarget.map { _ in ComputerMicrophoneCapture() }
    let audioTrack = audioConnection != nil || microphone != nil
      ? try RecordingAudioTrack(mixesComputerMicrophone: audioConnection != nil && microphone != nil) : nil
    let recording = NativeScreenRecording(
      source: source,
      audioConnection: audioConnection,
      computerMicrophone: microphone,
      audioTrack: audioTrack
    )
    do {
      if let microphone, let target = computerMicrophoneTarget {
        try await microphone.start()
        let deviceClockOffset = try await DeviceClock.offset(for: target)
        recording.listenToComputerMicrophone(microphone, deviceClockOffset: deviceClockOffset)
      }
      if let audioConnection, let audioTrack {
        audioConnection.start { [weak recording] event in recording?.receiveAudioEvent(event) } failed: { [weak recording] error in
          recording?.beginFinish(error: error)
        }
        try await recording.waitForStartup("Recording did not receive device audio") { audioTrack.hasBufferedDeviceSamples }
      }
      recording.source.start { [weak recording] event in recording?.receive(event) }
      try await recording.waitForStartup("Recording did not receive a video frame") { recording.writer != nil }
      if let audioTrack {
        let message = switch (microphone != nil, audioConnection != nil) {
        case (true, true): "Recording did not receive both device audio and computer microphone audio"
        case (true, false): "Recording did not receive computer microphone audio"
        default: "Recording did not receive device audio"
        }
        try await recording.waitForStartup(message) { audioTrack.endTime != nil }
      }
      return recording
    } catch {
      await recording.remove()
      throw error
    }
  }

  private func listenToComputerMicrophone(_ microphone: ComputerMicrophoneCapture, deviceClockOffset: CMTime) {
    computerAudioTask = Task { [weak self] in
      do {
        for try await packet in microphone.packets {
          guard let self else { return }
          try audioTrack?.receiveComputerMicrophone(packet, deviceClockOffset: deviceClockOffset, until: computerMicrophoneStopTime)
        }
      } catch {
        self?.beginFinish(error: error)
        throw error
      }
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
    computerMicrophoneStopTime = CMClockGetTime(CMClockGetHostTimeClock())
    let videoEnd = videoTrack.endTime(at: clock.now)
    finishTask = Task {
      await computerMicrophone?.stop()
      let microphoneResult = await computerAudioTask?.result
      await source.waitUntilStopped()
      await audioConnection?.waitUntilStopped()
      let audioResult = Result { try audioTrack?.finish() }
      let end = [videoEnd, audioTrack?.endTime].compactMap(\.self).max()
      try await writer?.finish(at: end)
      if let error { throw error }
      try microphoneResult?.get()
      _ = try audioResult.get()
    }
    for waiter in stopWaiters {
      waiter.resume()
    }
    stopWaiters.removeAll()
  }
}

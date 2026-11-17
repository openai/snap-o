import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct NativeScreenRecordingTests {
  @Test(arguments: [0.0, 0.25, 3.0])
  func passesTimestampsAndStoppedTimeToWriter(tail: Double) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let writer = Writer()
    let recording = NativeScreenRecording(source: Source()) { _, _, start, _ in
      writer.start = start.seconds
      return writer
    }
    let format = try makeFormat()
    recording.receive(.format(format))
    for timestamp in [0.0, 0.25, 1.5] {
      try recording.receive(.sample(makeSample(format, at: timestamp), isKeyFrame: timestamp == 0))
    }
    await clock.advance(by: .seconds(tail))
    try await recording.stop()
    #expect(writer.start == 0)
    #expect(writer.timestamps == [0, 0.25, 1.5])
    #expect(try abs(#require(writer.end) - (1.5 + max(1.0 / 60, tail))) < 0.00001)
  }

  @Test
  func disconnectedRecordingKeepsRecoveryFileUntilSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    let recording = NativeScreenRecording(source: Source()) { url, _, _, _ in
      temporary = url
      try Data("recording".utf8).write(to: url)
      return Writer()
    }
    let format = try makeFormat()
    recording.receive(.format(format))
    try recording.receive(.sample(makeSample(format, at: 0), isKeyFrame: true))
    recording.receive(.stopped(CocoaError(.fileReadUnknown)))
    await #expect(throws: (any Error).self) { try await recording.waitUntilStopped() }
    let existing = root.appendingPathComponent("existing.mp4")
    try Data("existing".utf8).write(to: existing)
    await #expect(throws: (any Error).self) { try await recording.save(to: existing) }
    await recording.close()
    let recovery = try #require(temporary)
    #expect(FileManager.default.fileExists(atPath: recovery.path))
    let saved = root.appendingPathComponent("saved.mp4")
    try await recording.save(to: saved)
    await recording.close()
    #expect(!FileManager.default.fileExists(atPath: recovery.path))
    #expect(try Data(contentsOf: saved) == Data("recording".utf8))
  }

  @Test
  func alignsBufferedAudioToTheFirstKeyframeAndKeepsTheAudioTail() async throws {
    let writer = Writer()
    let recording = try NativeScreenRecording(source: Source(), audioTrack: RecordingAudioTrack()) { _, _, _, _ in writer }
    let format = try makeFormat()
    let pcm = Data(repeating: 0, count: 960 * DeviceAudioPacket.bytesPerFrame)
    func sendAudio(_ millis: Int64) {
      recording.receiveAudioEvent(.samples(DeviceAudioPacket(timestamp: CMTime(value: millis, timescale: 1000), pcm: pcm)))
    }
    sendAudio(960)
    sendAudio(990)
    recording.receive(.format(format))
    try recording.receive(.sample(makeSample(format, at: 0.98), isKeyFrame: false))
    #expect(writer.timestamps.isEmpty)
    try recording.receive(.sample(makeSample(format, at: 1), isKeyFrame: true))
    sendAudio(1010)
    try await recording.stop()
    #expect(writer.timestamps == [1, 1, 1.01])
    #expect(writer.audioFrames == [480, 960])
    #expect(writer.end == 1.03)
  }

  @Test
  func formatCanChangeUntilTheFirstKeyframe() async throws {
    let writer = Writer()
    var initialWidth: Int32?
    let recording = NativeScreenRecording(source: Source()) { _, format, _, _ in
      initialWidth = CMVideoFormatDescriptionGetDimensions(format).width
      return writer
    }
    let small = try makeFormat()
    let large = try makeFormat(width: 64)
    recording.receive(.format(small))
    recording.receive(.format(large))
    try recording.receive(.sample(makeSample(large, at: 1), isKeyFrame: true))
    recording.receive(.format(large))
    try recording.receive(.sample(makeSample(large, at: 2), isKeyFrame: false))
    recording.receive(.format(small))
    await #expect(throws: (any Error).self) { try await recording.waitUntilStopped() }
    #expect(initialWidth == 64)
    #expect(writer.timestamps == [1, 2])
    #expect(writer.isComplete)
  }

  @Test(arguments: [true, false])
  func warnsAboutSilencedMicrophoneDuringTheSavedRecording(silencedAtKeyframe: Bool) async throws {
    let writer = Writer()
    let recording = try NativeScreenRecording(source: Source(), audioTrack: RecordingAudioTrack()) { _, _, _, _ in writer }
    recording.receiveAudioEvent(.microphoneSilenced(true))
    if !silencedAtKeyframe { recording.receiveAudioEvent(.microphoneSilenced(false)) }
    let format = try makeFormat()
    recording.receive(.format(format))
    try recording.receive(.sample(makeSample(format, at: 1), isKeyFrame: true))
    #expect((recording.captureWarning != nil) == silencedAtKeyframe)
    recording.receiveAudioEvent(.microphoneSilenced(true))
    recording.receiveAudioEvent(.microphoneSilenced(false))
    try await recording.stop()
    #expect(recording.captureWarning?.contains("device microphone") == true)
    #expect(writer.isComplete)
  }

  private func makeFormat(width: Int32 = 32) throws -> CMVideoFormatDescription {
    var format: CMVideoFormatDescription?
    try #require(CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_H264,
      width: width,
      height: 32,
      extensions: nil,
      formatDescriptionOut: &format
    ) == noErr)
    return try #require(format)
  }

  private func makeSample(_ format: CMVideoFormatDescription, at timestamp: Double) throws -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 600),
      decodeTimeStamp: .invalid
    )
    try #require(CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      formatDescription: format,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sample
    ) == noErr)
    return try #require(sample)
  }

  private final class Writer: NativeRecordingWriter {
    var isComplete = false
    var start: Double?
    var end: Double?
    var timestamps: [Double] = []
    var audioFrames: [Int] = []
    func append(_ sample: CMSampleBuffer) {
      timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
      if let format = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio {
        audioFrames.append(CMSampleBufferGetNumSamples(sample))
      }
    }

    func finish(at end: CMTime?) async {
      self.end = end?.seconds
      isComplete = true
    }
  }

  private final class Source: LivePreviewFrameSource {
    var hasIndependentFrames: Bool {
      false
    }

    func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {}
    func stop() {}
    func waitUntilStopped() async {}
  }
}

import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct NativeRecordingTests {
  @Test(arguments: [0.0, 0.25, 3.0])
  func passesTimestampsAndStoppedTimeToWriter(tail: Double) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self) var clock
    let writer = Writer()
    let recording = NativeScreenRecording(source: Source()) { _, _, start in
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
    let recording = NativeScreenRecording(source: Source()) { url, _, _ in
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

  private func makeFormat() throws -> CMVideoFormatDescription {
    var format: CMVideoFormatDescription?
    try #require(CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_H264,
      width: 32,
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
    func append(_ sample: CMSampleBuffer) {
      timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
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

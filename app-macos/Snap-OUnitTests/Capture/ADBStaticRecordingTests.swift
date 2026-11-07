import AVFoundation
import Dependencies
import Foundation
import Testing

struct ADBStaticRecordingTests {
  @Test(arguments: [false, true])
  func repairPassesDurationAndPreservesSourceOnCancellation(cancel: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("static.mp4")
    try Data("original".utf8).write(to: url)
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: .zero, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    try #require(CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      formatDescription: nil,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sample
    ) == noErr)
    let frame = try StaticRecordingFrame(sample: #require(sample), transform: CGAffineTransform(rotationAngle: .pi / 2))
    try await withDependencies {
      $0.staticRecording.readFrame = { _ in frame }
      $0.staticRecording.writeFrame = { received, duration, destination in
        #expect(received.sample === frame.sample)
        #expect(received.transform == frame.transform)
        #expect(duration == 5)
        try Data("repaired".utf8).write(to: destination)
      }
    } operation: {
      let task = Task {
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        try await ADBRecordingFile.restoreStaticDuration(at: url, recordedDuration: .seconds(5))
      }
      if cancel {
        await #expect(throws: CancellationError.self) { try await task.value }
      } else {
        try await task.value
      }
    }
    #expect(try Data(contentsOf: url) == Data((cancel ? "original" : "repaired").utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["static.mp4"])
  }

  @Test
  func nonStaticRecordingDoesNotWriteAnything() async throws {
    try await withDependencies {
      $0.staticRecording.readFrame = { _ in nil }
    } operation: {
      try await ADBRecordingFile.restoreStaticDuration(at: URL(filePath: "/unused.mp4"), recordedDuration: .seconds(5))
    }
  }
}

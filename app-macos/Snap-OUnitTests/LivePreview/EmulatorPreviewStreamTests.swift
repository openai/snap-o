import Foundation
import Testing

@MainActor
struct EmulatorPreviewStreamTests {
  private let requested = LivePreviewFrameSize.preview(CGSize(width: 540, height: 1200))
  private let native = CGSize(width: 1080, height: 2400)
  private enum Failure: Error { case probe, stream }

  @Test
  func failedProbeStillStartsNativeFrameReceiver() async throws {
    var received: [LivePreviewFrameSize] = []
    try await EmulatorPreviewStream.run(requestedSize: requested) {
      throw Failure.probe
    } receiveFrames: { size, _ in
      received.append(size)
      return nil
    }
    #expect(received == [.native])
  }

  @Test
  func laterProbeFailureSwitchesToNativeFrames() async throws {
    var queries = 0
    let read: () async throws -> CGSize? = {
      queries += 1
      if queries > 1 { throw Failure.probe }
      return native
    }
    var received: [LivePreviewFrameSize] = []
    try await EmulatorPreviewStream.run(requestedSize: requested, readDisplaySize: read) { size, _ in
      received.append(size)
      guard size != .native else { return nil }
      return try await EmulatorPreviewStream.DisplayChange(size: EmulatorPreviewStream.readSize(read))
    }
    #expect(received == [requested, .native])
  }

  @Test
  func nativeRecordingDoesNotQueryDisplaySize() async throws {
    try await EmulatorPreviewStream.run(requestedSize: .native) {
      Issue.record("Native recording must use frame dimensions without a size query")
      return nil
    } receiveFrames: { _, _ in nil }
  }

  @Test
  func cancellingProbeDoesNotStartFrameReceiver() async {
    let probe = TestSuspension()
    var received: [LivePreviewFrameSize] = []
    let task = Task {
      try await EmulatorPreviewStream.run(requestedSize: requested) {
        try await probe.wait()
        return native
      } receiveFrames: { size, _ in
        received.append(size)
        return nil
      }
    }
    await probe.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(received.isEmpty)
  }

  @Test
  func cancelledSizeChangeDoesNotStartReplacementStream() async {
    let change = TestSuspension()
    var received: [LivePreviewFrameSize] = []
    let task = Task {
      try await EmulatorPreviewStream.run(requestedSize: requested) {
        native
      } receiveFrames: { size, _ in
        received.append(size)
        try? await change.wait()
        return .init(size: nil)
      }
    }
    await change.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(received == [requested])
  }

  @Test
  func streamFailureDoesNotTriggerNativeFallback() async {
    var received: [LivePreviewFrameSize] = []
    await #expect(throws: Failure.stream) {
      try await EmulatorPreviewStream.run(requestedSize: requested) {
        native
      } receiveFrames: { size, _ in
        received.append(size)
        throw Failure.stream
      }
    }
    #expect(received == [requested])
  }
}

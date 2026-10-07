import AVFoundation
import Clocks
import Dependencies
import Foundation
import Testing

@main
@MainActor
struct VideoStreamTests {
  static func main() async throws {
    try await withDependencies {
      $0.context = .test
      $0.continuousClock = TestClock()
    } operation: {
      await requestsKeyFrameOnlyForJoinedConsumers()
      await consumersReleaseIndependently()
      await restartWaitsForFinalConsumerCleanup()
      await oldSubscriptionCannotRemoveReplacement()
      await cancelDuringConnectionCreationJoinsLateSocket()
      await replacementConnectionDoesNotWaitForOldTarget()
      try await deadlineJoinsTransportCleanup()
      await sessionWaitersJoinCleanup()
      await structuredFailureStopsPreview()
      await rgbaSubscribersReceiveRenderedAndCachedFrames()
      await recordingWaitersJoinSourceCleanup()
      try await emulatorSubscribersShareStartupAndFinalCleanup()
      try await emulatorCancellationJoinsEndpointLookup()
      try await emulatorInvalidationEndsSession()
      try await emulatorDeadlineEndsSession()
    }
    print("Shared video lifetime tests passed")
    await exit(Testing.__swiftPMEntryPoint())
  }

  static func target(_ serial: String = "test-device") -> DeviceTarget {
    DeviceTarget(serial: serial, transportID: "1")
  }

  static func structuredFailureStopsPreview() async {
    let target = target()
    let socket = ADBSocketConnection()
    let probe = prepare(target, socket)
    let hub = DeviceVideoHub()
    let video = PreviewVideo {
      LivePreviewSession(deviceID: target.serial, densityScale: nil, source: DeviceVideoSource(target: target, hub: hub))
    } canReconnect: { true }
    video.start()
    await waitForReads(socket)
    socket.append(Data([3, 5, 0, 0x80, 0, 0x10, 1]))
    let failure = DeviceVideoFailure(stage: .configuration, retryable: false, codecError: -2_147_479_551)
    await waitForObservedTestState { video.phase == .failed(failure.localizedDescription) }
    precondition(video.session == nil)
    await video.close()
    await assertOpened(1, probe: probe)
    precondition(socket.isClosed)
  }

  static func prepare(_ target: DeviceTarget, _ sockets: ADBSocketConnection..., startup: TestGate? = nil) -> VideoConnectionProbe {
    let probe = VideoConnectionProbe(sockets, startup: startup)
    VideoConnectionRegistry.shared.register(probe, for: target)
    return probe
  }

  static func rgbaSubscribersReceiveRenderedAndCachedFrames() async {
    let target = target()
    let socket = ADBSocketConnection()
    _ = prepare(target, socket)
    let hub = DeviceVideoHub()
    let first = DeviceVideoSource(target: target, hub: hub)
    let received = TestValue(false)
    first.start {
      if case .sample(let sample, let keyFrame) = $0 {
        precondition(keyFrame)
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("Missing pixel buffer") }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixels) else { preconditionFailure("Missing pixel data") }
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        precondition(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [0, 0, 255, 255])
        received.value = true
      }
    }
    await waitForReads(socket)
    var packet = Data([1])
    for value in [UInt32(2), 2, 160, 0] {
      withUnsafeBytes(of: value.bigEndian) { packet.append(contentsOf: $0) }
    }
    packet.append(4)
    for value in [UInt32(2), 2, 0, 123, 15] {
      withUnsafeBytes(of: value.bigEndian) { packet.append(contentsOf: $0) }
    }
    packet.append(contentsOf: [120, 1, 251, 207, 192, 240, 255, 63, 18, 6, 0, 67, 204, 7, 249])
    socket.append(packet)
    await waitForObservedTestState { received.value }
    precondition(first.hasIndependentFrames)
    let second = DeviceVideoSource(target: target, hub: hub)
    let replayed = TestValue(false)
    second.start { if case .sample = $0 { replayed.value = true } }
    await waitForObservedTestState { replayed.value }
    let recorder = DeviceVideoSource(target: target, hub: hub, replaysLastFrame: false)
    let fresh = TestValue(false)
    recorder.start { if case .sample = $0 { fresh.value = true } }
    precondition(!fresh.value, "Recording must wait for a fresh timestamp")
    socket.append(Data(packet.dropFirst(17)))
    await waitForObservedTestState { fresh.value }
    recorder.stop()
    await recorder.waitUntilStopped()
    first.stop()
    await first.waitUntilStopped()
    precondition(!socket.isClosed)
    second.stop()
    await second.waitUntilStopped()
    precondition(socket.isClosed)
  }

  static func assertOpened(_ expected: Int, probe: VideoConnectionProbe) async {
    let opened = await probe.opened
    precondition(opened == expected)
  }

  static func waitForReads(_ socket: ADBSocketConnection) async {
    // The shell header and video magic are read before waiting for the first video packet.
    await waitForActorTestState { socket.readCount >= 3 }
  }

  static func requestsKeyFrameOnlyForJoinedConsumers() async {
    let target = target()
    let socket = ADBSocketConnection()
    _ = prepare(target, socket)
    let hub = DeviceVideoHub()
    let first = DeviceVideoSource(target: target, hub: hub)
    first.start { _ in }
    await waitForReads(socket)
    precondition(socket.writeCount == 0, "Starting the encoder must not request another keyframe")

    let second = DeviceVideoSource(target: target, hub: hub)
    second.start { _ in }
    await waitForActorTestState { socket.writeCount == 1 }
    first.stop()
    await first.waitUntilStopped()
    precondition(!socket.isClosed)
    second.stop()
    await second.waitUntilStopped()
    precondition(socket.isClosed)
  }

  static func consumersReleaseIndependently() async {
    let target = target()
    let socket = ADBSocketConnection()
    let probe = prepare(target, socket)
    let hub = DeviceVideoHub()
    let first = DeviceVideoSource(target: target, hub: hub)
    let second = DeviceVideoSource(target: target, hub: hub)
    first.start { _ in }
    second.start { _ in }
    await waitForReads(socket)
    await assertOpened(1, probe: probe)
    first.stop()
    await first.waitUntilStopped()
    precondition(!socket.isClosed)
    let density = TestValue<CGFloat?>(nil)
    // The remaining subscription must still receive live data.
    socket.append(Data([1, 0, 0, 0, 100, 0, 0, 0, 100, 0, 0, 1, 64, 0, 0, 0, 0]))
    let third = DeviceVideoSource(target: target, hub: hub)
    third.start { if case .density(let scale) = $0 { density.value = scale } }
    await waitForObservedTestState { density.value == 2 }
    second.stop()
    await second.waitUntilStopped()
    precondition(!socket.isClosed)
    third.stop()
    await third.waitUntilStopped()
    precondition(socket.isClosed)
    first.start { _ in preconditionFailure("Stopped subscription restarted") }
    await assertOpened(1, probe: probe)
  }

  static func restartWaitsForFinalConsumerCleanup() async {
    let target = target()
    let oldSocket = ADBSocketConnection()
    oldSocket.holdReaderAfterClose()
    let newSocket = ADBSocketConnection()
    let probe = prepare(target, oldSocket, newSocket)
    let hub = DeviceVideoHub()
    let old = DeviceVideoSource(target: target, hub: hub)
    old.start { _ in }
    await waitForReads(oldSocket)
    old.stop()
    let completed = TestValue(false)
    let stopping = await startTestTask {
      await old.waitUntilStopped()
      completed.value = true
    }
    precondition(!completed.value)
    let next = DeviceVideoSource(target: target, hub: hub)
    next.start { _ in }
    await assertOpened(1, probe: probe)
    oldSocket.releaseReader()
    await stopping.value
    await waitForReads(newSocket)
    await assertOpened(2, probe: probe)
    next.stop()
    await next.waitUntilStopped()
  }

  static func oldSubscriptionCannotRemoveReplacement() async {
    let target = target()
    let oldSocket = ADBSocketConnection()
    let newSocket = ADBSocketConnection()
    let probe = prepare(target, oldSocket, newSocket)
    let hub = DeviceVideoHub()
    let old = DeviceVideoSource(target: target, hub: hub)
    let failed = TestValue(false)
    old.start { if case .stopped = $0 { failed.value = true } }
    await waitForReads(oldSocket)
    oldSocket.append(Data([255]))
    await waitForObservedTestState { failed.value }
    let next = DeviceVideoSource(target: target, hub: hub)
    next.start { _ in }
    await waitForReads(newSocket)
    old.stop()
    await old.waitUntilStopped()
    precondition(!newSocket.isClosed)
    let sibling = DeviceVideoSource(target: target, hub: hub)
    sibling.start { _ in }
    await assertOpened(2, probe: probe)
    next.stop()
    await next.waitUntilStopped()
    precondition(!newSocket.isClosed)
    sibling.stop()
    await sibling.waitUntilStopped()
    precondition(newSocket.isClosed)
  }

  static func cancelDuringConnectionCreationJoinsLateSocket() async {
    let target = target()
    let socket = ADBSocketConnection()
    let startup = TestGate()
    _ = prepare(target, socket, startup: startup)
    let source = DeviceVideoSource(target: target, hub: DeviceVideoHub())
    source.start { _ in preconditionFailure("Cancelled source delivered an event") }
    await waitForActorTestState { await startup.waitCount == 1 }
    source.stop()
    let completed = TestValue(false)
    let stopping = await startTestTask {
      await source.waitUntilStopped()
      completed.value = true
    }
    precondition(!completed.value)
    await startup.open()
    await stopping.value
    precondition(socket.isClosed && socket.readCount == 0)
  }

  static func replacementConnectionDoesNotWaitForOldTarget() async {
    let oldTarget = target()
    let newTarget = target()
    let oldSocket = ADBSocketConnection()
    oldSocket.holdReaderAfterClose()
    let newSocket = ADBSocketConnection()
    _ = prepare(oldTarget, oldSocket)
    _ = prepare(newTarget, newSocket)
    let hub = DeviceVideoHub()
    let old = DeviceVideoSource(target: oldTarget, hub: hub)
    old.start { _ in }
    await waitForReads(oldSocket)
    oldTarget.invalidate()
    old.stop()
    let next = DeviceVideoSource(target: newTarget, hub: hub)
    next.start { _ in }
    await waitForReads(newSocket)
    oldSocket.releaseReader()
    await old.waitUntilStopped()
    precondition(!newSocket.isClosed)
    next.stop()
    await next.waitUntilStopped()
  }

  static func deadlineJoinsTransportCleanup() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let target = target()
      let socket = ADBSocketConnection()
      socket.holdReaderAfterClose()
      _ = prepare(target, socket)
      let source = DeviceVideoSource(target: target, hub: DeviceVideoHub())
      let failed = TestValue(false)
      source.start { if case .stopped(let error) = $0 { failed.value = error != nil } }
      await waitForReads(socket)
      await clock.advance(by: .seconds(8))
      await waitForObservedTestState { failed.value }
      source.stop()
      let completed = TestValue(false)
      let stopping = await startTestTask {
        await source.waitUntilStopped()
        completed.value = true
      }
      precondition(socket.isClosed && !completed.value)
      socket.releaseReader()
      await stopping.value
      try await clock.checkSuspension()
    }
  }

  static func recordingWaitersJoinSourceCleanup() async {
    let source = HeldFrameSource()
    let recording = NativeScreenRecording(source: source)
    let completed = TestValue(0)
    let first = await startTestTask { try? await recording.stop()
      completed.value += 1
    }
    let second = await startTestTask { await recording.close()
      completed.value += 1
    }
    await waitForActorTestState { await source.cleanup.waitCount == 1 }
    precondition(source.stops == 1 && completed.value == 0)
    await source.cleanup.open()
    await first.value
    await second.value
    precondition(completed.value == 2)
  }

  static func emulatorSubscribersShareStartupAndFinalCleanup() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let target = target("emulator-5554")
      let gate = TestGate()
      let probe = EmulatorEndpointProbe(gate: gate)
      EmulatorEndpointRegistry.shared.register(probe, serial: target.serial)
      let hub = DeviceVideoHub()
      let first = LivePreviewSession(
        deviceID: target.serial, densityScale: nil, source: DeviceVideoSource(target: target, hub: hub)
      )
      let second = LivePreviewSession(
        deviceID: target.serial, densityScale: nil, source: DeviceVideoSource(target: target, hub: hub)
      )
      await gate.waitUntilEntered()
      first.cancel()
      _ = await first.waitUntilStop()
      precondition(probe.requestCount == 1 && probe.closeCount == 0)
      second.cancel()
      let completed = TestValue(false)
      let close = await startTestTask {
        _ = await second.waitUntilStop()
        completed.value = true
      }
      precondition(!completed.value)
      await gate.open()
      await close.value
      precondition(probe.closeCount == 1)
      try await clock.checkSuspension()
    }
  }

  static func emulatorCancellationJoinsEndpointLookup() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let target = target("emulator-5554")
      let gate = TestGate()
      let probe = EmulatorEndpointProbe(gate: gate)
      EmulatorEndpointRegistry.shared.register(probe, serial: target.serial)
      let source = EmulatorPreviewFrameSource(target: target)
      let session = LivePreviewSession(deviceID: target.serial, densityScale: nil, source: source)
      await waitForActorTestState { await gate.waitCount == 1 }
      session.cancel()
      let completed = TestValue(false)
      let stop = await startTestTask {
        _ = await session.waitUntilStop()
        completed.value = true
      }
      precondition(!completed.value && probe.closeCount == 0)
      await gate.open()
      await stop.value
      precondition(probe.closeCount == 1)
      try await clock.checkSuspension()
    }
  }

  static func emulatorInvalidationEndsSession() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let target = target("emulator-5556")
      let probe = EmulatorEndpointProbe()
      EmulatorEndpointRegistry.shared.register(probe, serial: target.serial)
      let source = EmulatorPreviewFrameSource(target: target)
      let session = LivePreviewSession(deviceID: target.serial, densityScale: nil, source: source)
      await waitForActorTestState { probe.requestCount == 1 }
      target.invalidate()
      let error = await session.waitUntilStop()
      precondition(error != nil && probe.closeCount == 1)
      try await clock.checkSuspension()
    }
  }

  static func emulatorDeadlineEndsSession() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let target = target("emulator-5558")
      let gate = TestGate()
      let probe = EmulatorEndpointProbe(gate: gate)
      EmulatorEndpointRegistry.shared.register(probe, serial: target.serial)
      let source = EmulatorPreviewFrameSource(target: target)
      let session = LivePreviewSession(deviceID: target.serial, densityScale: nil, source: source)
      await waitForActorTestState { await gate.waitCount == 1 }
      let ready = Task { try await session.waitUntilReady() }
      await clock.advance(by: .seconds(15))
      do {
        _ = try await ready.value
        preconditionFailure("Timed-out emulator became ready")
      } catch {
        precondition(error is EmulatorPreviewError)
      }
      await gate.open()
      let error = await session.waitUntilStop()
      precondition(error is EmulatorPreviewError && probe.closeCount == 1)
      try await clock.checkSuspension()
    }
  }

  static func sessionWaitersJoinCleanup() async {
    let source = HeldFrameSource()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    let ready = Task { try await session.waitUntilReady() }
    let completed = TestValue(0)
    let first = await startTestTask { _ = await session.waitUntilStop()
      completed.value += 1
    }
    let second = await startTestTask { _ = await session.waitUntilStop()
      completed.value += 1
    }
    session.cancel()
    session.cancel()
    do {
      _ = try await ready.value
      preconditionFailure("Cancelled session became ready")
    } catch is CancellationError {} catch {
      preconditionFailure("Unexpected readiness error: \(error)")
    }
    await waitForActorTestState { await source.cleanup.waitCount == 2 }
    precondition(source.stops == 1 && completed.value == 0)
    await source.cleanup.open()
    await first.value
    await second.value
    precondition(completed.value == 2)
    _ = await session.waitUntilStop()
  }
}

@MainActor
private final class HeldFrameSource: LivePreviewFrameSource {
  let hasIndependentFrames = true
  let cleanup = TestGate()
  var stops = 0
  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {}
  func stop() {
    stops += 1
  }

  func waitUntilStopped() async {
    await cleanup.wait()
  }
}

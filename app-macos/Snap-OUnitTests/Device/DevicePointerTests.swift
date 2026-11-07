import Foundation
import Testing

struct DevicePointerTests {
  private let target = DeviceTarget(serial: "pointer-device", transportID: "1")

  private func event(_ action: LivePreviewPointerAction, source: LivePreviewPointerSource = .touchscreen) -> LivePreviewPointerEvent {
    LivePreviewPointerEvent(
      target: target,
      action: action,
      source: source,
      locations: [CGPoint(x: 4.5, y: 7)],
      displaySize: CGSize(width: 100, height: 200)
    )
  }

  @Test func framesCoordinatesAndClampsToDisplay() throws {
    var value = event(.down)
    value.locations = [CGPoint(x: -4, y: 240), CGPoint(x: 4.5, y: 7)]
    let frame = try DevicePointerProtocol.frame(value)
    let words = stride(from: 0, to: frame.count, by: 4).map { start in
      frame[start ..< start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    #expect(words == [0, 0, 2, 100, 200, Float(0).bitPattern, Float(199).bitPattern, Float(4.5).bitPattern, Float(7).bitPattern])
  }

  @Test func rejectsInvalidCoordinatesAndCounts() {
    for points in [[], [CGPoint(x: Double.nan, y: 0)], Array(repeating: CGPoint.zero, count: 11)] {
      var value = event(.down)
      value.locations = points
      #expect(throws: (any Error).self) { try DevicePointerProtocol.frame(value) }
    }
    var mouse = event(.down, source: .mouse)
    mouse.locations = [.zero, .zero]
    #expect(throws: (any Error).self) { try DevicePointerProtocol.frame(mouse) }
  }

  @Test func transportWritesWithoutWaitingForPerEventReplies() async throws {
    let connection = ScriptedADBConnection(reads: [.data(Data([1, 4, 0, 0, 0, 0, 0, 0, 1])), .waitForClose])
    let adb = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    let transport = try await DevicePointerTransport.connect(target: target, adb: adb, helper: { Data([1]) })
    try await connection.waitUntilBlocked()
    let down = try DevicePointerProtocol.frame(event(.down))
    let up = try DevicePointerProtocol.frame(event(.up))
    try await transport.send(down)
    try await transport.send(up)
    #expect(try connection.written == (ADBShellV2Stream.standardInput(down) + ADBShellV2Stream.standardInput(up)))
    transport.close()
    await transport.waitUntilStopped()
    #expect(connection.isClosed)
  }

  @Test func rejectsWrongHelperVersionAndClosesConnection() async {
    let connection = ScriptedADBConnection(reads: [.data(Data([1, 4, 0, 0, 0, 0, 0, 0, 2]))])
    await #expect(throws: (any Error).self) {
      _ = try await DevicePointerTransport.connect(
        target: target,
        adb: ADBClient(discoveryTimeout: .seconds(2)) { connection },
        helper: { Data([1]) }
      )
    }
    #expect(connection.isClosed)
  }

  @Test func backendReusesConnectionAndNeverReplaysFailedGesture() async throws {
    let first = PointerTransportDouble()
    let next = PointerTransportDouble()
    let factory = PointerTransportFactory([first, next])
    let backend = InputManagerLivePreviewPointerBackend(target: target) { await factory.next() }
    try await backend.send(event(.down))
    first.failWrites()
    await #expect(throws: (any Error).self) { try await backend.send(event(.move)) }
    try await backend.send(event(.move))
    try await backend.send(event(.up))
    #expect(await factory.count == 1)
    #expect(first.isClosed)
    try await backend.send(event(.down))
    try await backend.send(event(.up))
    #expect(await factory.count == 2)
    #expect(next.frames.count == 2)
    await backend.stop()
    #expect(next.isClosed)
    await #expect(throws: (any Error).self) { try await backend.send(event(.down)) }
  }

  @Test func stopDuringStartupClosesLateConnection() async {
    let transport = PointerTransportDouble()
    let startup = PointerStartupGate()
    let backend = InputManagerLivePreviewPointerBackend(target: target) { await startup.wait()
      return transport
    }
    let send = Task { try await backend.send(event(.down)) }
    await startup.waitUntilEntered()
    let stopped = Task { await backend.stop() }
    await startup.waitUntilCancelled()
    await startup.release()
    await stopped.value
    _ = try? await send.value
    #expect(transport.isClosed)
    #expect(transport.frames.isEmpty)
  }
}

private final class PointerTransportDouble: LivePreviewPointerTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false
  private var closed = false
  private var sent: [Data] = []
  var isClosed: Bool {
    lock.withLock { closed }
  }

  var frames: [Data] {
    lock.withLock { sent }
  }

  func failWrites() {
    lock.withLock { failed = true }
  }

  func send(_ frame: Data) async throws {
    try lock.withLock {
      if failed || closed { throw ADBError.protocolFailure("Test write failure") }
      sent.append(frame)
    }
  }

  func close() {
    lock.withLock { closed = true }
  }

  func waitUntilStopped() async {}
}

private actor PointerTransportFactory {
  var values: [PointerTransportDouble]
  private(set) var count = 0
  init(_ values: [PointerTransportDouble]) {
    self.values = values
  }

  func next() -> PointerTransportDouble {
    count += 1
    return values.removeFirst()
  }
}

private actor PointerStartupGate {
  private let changed = TestSignal()
  private var continuation: CheckedContinuation<Void, Never>?
  private var cancelled = false
  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation = $0
        changed.signal()
      }
    } onCancel: { Task { await self.markCancelled() } }
  }

  func waitUntilEntered() async {
    while continuation == nil {
      try? await changed.wait(after: changed.revision)
    }
  }

  private func markCancelled() {
    cancelled = true
    changed.signal()
  }

  func waitUntilCancelled() async {
    while !cancelled {
      try? await changed.wait(after: changed.revision)
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

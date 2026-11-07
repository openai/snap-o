import Foundation

/// Lazily opens one helper per device connection, shared by mouse and touch events.
actor InputManagerLivePreviewPointerBackend: LivePreviewPointerBackend {
  private let target: DeviceTarget
  private let connect: @Sendable () async throws -> any LivePreviewPointerTransport
  private var transport: (any LivePreviewPointerTransport)?
  private var startup: Task<any LivePreviewPointerTransport, Error>?
  private var stopped = false
  private var failedGesture = false

  init(target: DeviceTarget, connect: @escaping @Sendable () async throws -> any LivePreviewPointerTransport) {
    self.target = target
    self.connect = connect
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    guard !stopped, target.isValid else { throw CancellationError() }
    guard event.target == target else { throw ADBError.protocolFailure("Pointer target changed") }
    let frame = try DevicePointerProtocol.frame(event)
    if failedGesture {
      guard event.action == .down else { return }
      failedGesture = false
    }
    do {
      let current = try await connection()
      try Task.checkCancellation()
      guard !stopped, target.isValid else { throw CancellationError() }
      try await current.send(frame)
    } catch {
      // Never replay a partially delivered gesture on a replacement connection.
      failedGesture = true
      let old = transport
      transport = nil
      old?.close()
      await old?.waitUntilStopped()
      throw error
    }
  }

  private func connection() async throws -> any LivePreviewPointerTransport {
    if let transport { return transport }
    let task: Task<any LivePreviewPointerTransport, Error>
    if let startup { task = startup } else {
      task = Task { try await connect() }
      startup = task
    }
    do {
      let ready = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: { task.cancel() }
      guard !stopped, target.isValid else {
        ready.close()
        await ready.waitUntilStopped()
        throw CancellationError()
      }
      transport = ready
      startup = nil
      return ready
    } catch {
      startup = nil
      throw error
    }
  }

  func stop() async {
    stopped = true
    let pending = startup
    pending?.cancel()
    transport?.close()
    if let ready = try? await pending?.value {
      ready.close()
      await ready.waitUntilStopped()
    }
    await transport?.waitUntilStopped()
    transport = nil
    startup = nil
  }
}

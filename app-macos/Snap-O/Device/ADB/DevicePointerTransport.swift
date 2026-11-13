import Foundation

protocol LivePreviewPointerTransport: Sendable {
  func send(_ frame: Data) async throws
  func close()
  func waitUntilStopped() async
}

/// One ordered input stream; the reader detects helper failure without delaying writes.
struct DevicePointerTransport: LivePreviewPointerTransport {
  private let connection: any ADBConnection
  private let queue: DispatchQueue
  private let reader: Task<Void, Never>

  static func connect(
    target: DeviceTarget,
    adb: ADBClient = ADBClient(),
    helper: @Sendable () throws -> Data = DeviceHelper.bundledBytes
  ) async throws -> Self {
    let deviceHelper = try DeviceHelper(helper())
    let session = try await deviceHelper.connect(.pointer, serial: target.serial, adb: adb.bound(to: target))
    let connection = session.connection
    let queue = DispatchQueue(label: "snapo.pointer.commands")
    guard session.header.reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == DevicePointerProtocol.version else {
      connection.close()
      throw ADBError.protocolFailure("Unsupported pointer helper version")
    }
    let reader = Task {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          var stream = session.stream
          // After readiness, any output or exit means the helper stopped accepting input.
          _ = try? stream.readExactly(1, read: connection.readChunk)
          connection.close()
          continuation.resume()
        }
      }
    }
    return Self(connection: connection, queue: queue, reader: reader)
  }

  func send(_ frame: Data) async throws {
    let packet = try ADBShellV2Stream.standardInput(frame)
    try await Self.perform(connection: connection, queue: queue) {
      try connection.writeFully(packet)
    }
  }

  func close() {
    connection.close()
  }

  func waitUntilStopped() async {
    await reader.value
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }

  private static func perform<Value: Sendable>(
    connection: any ADBConnection, queue: DispatchQueue,
    operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async { continuation.resume(with: Result(catching: operation)) }
      }
    } onCancel: {
      connection.close()
    }
  }
}

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
    helper: @Sendable () throws -> Data = DeviceClipboardProtocol.bundledHelper
  ) async throws -> Self {
    let command = try DevicePointerProtocol.launchCommand(helper: helper())
    let connection = try await adb.bound(to: target).makeConnection()
    let queue = DispatchQueue(label: "snapo.pointer.commands")
    do {
      let stream = try await perform(connection: connection, queue: queue) {
        try connection.withRequestTimeout(.seconds(8)) {
          try connection.sendTransport(to: target.serial)
          _ = try connection.sendHostCommand("shell,v2,raw:" + command, expectsResponse: false)
          var stream = ADBShellV2Stream()
          let version = try stream.readExactly(4, read: connection.readChunk).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
          guard version == DevicePointerProtocol.version else {
            throw ADBError.protocolFailure("Unsupported pointer helper version")
          }
          return stream
        }
      }
      let reader = Task {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            var stream = stream
            // After readiness, any output or exit means the helper stopped accepting input.
            _ = try? stream.readExactly(1, read: connection.readChunk)
            connection.close()
            continuation.resume()
          }
        }
      }
      return Self(connection: connection, queue: queue, reader: reader)
    } catch {
      connection.close()
      throw error
    }
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

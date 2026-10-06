import Foundation

struct DeviceClipboardTransport: ClipboardTransport {
  private let connection: any ADBConnection
  private let initialText: String
  private let reader = DispatchQueue(label: "snapo.clipboard.read")
  private let writer = DispatchQueue(label: "snapo.clipboard.write")

  static func connect(
    serial: String,
    adb: ADBClient = ADBClient(),
    helper: @Sendable () throws -> Data = DeviceClipboardProtocol.bundledHelper,
    isolation: isolated (any Actor)? = #isolation,
    body: (Self) async throws -> Void
  ) async throws {
    let command = try DeviceClipboardProtocol.launchCommand(helper: helper())
    let connection = try await adb.makeConnection()
    defer { connection.close() }
    try await withTaskCancellationHandler {
      let initialText = try await perform(on: .global(qos: .userInitiated)) {
        try connection.withRequestTimeout(.seconds(8)) {
          try connection.sendTransport(to: serial)
          _ = try connection.sendHostCommand("exec:" + command, expectsResponse: false)
          guard try DeviceClipboardProtocol.readNumber(connection) == 1 else {
            throw ADBError.protocolFailure("Unsupported clipboard helper version")
          }
          return try DeviceClipboardProtocol.readText(connection)
        }
      }
      try Task.checkCancellation()
      try await body(Self(connection: connection, initialText: initialText))
    } onCancel: {
      connection.close()
    }
  }

  func getText() async throws -> String {
    initialText
  }

  func setText(_ text: String) async throws {
    let frame = try DeviceClipboardProtocol.frame(text)
    try await Self.perform(on: writer) { try connection.writeFully(frame) }
  }

  func receive(_ onText: @escaping @Sendable (String) async -> Void) async throws {
    try await withTaskCancellationHandler {
      while true {
        try Task.checkCancellation()
        let text = try await Self.perform(on: reader) { try DeviceClipboardProtocol.readText(connection) }
        try Task.checkCancellation()
        await onText(text)
      }
    } onCancel: {
      connection.close()
    }
  }

  private static func perform<Value: Sendable>(
    on queue: DispatchQueue,
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }
}

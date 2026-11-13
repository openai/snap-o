import Foundation

struct DeviceKeyboardTransport: LivePreviewKeyboardTransport {
  static let version: UInt32 = 2
  let connection: any ADBConnection
  private let queue = DispatchQueue(label: "snapo.keyboard")

  static func connect(
    serial: String,
    adb: ADBClient = ADBClient(),
    helper: @Sendable () throws -> Data = DeviceHelper.bundledBytes
  ) async throws -> Self {
    let deviceHelper = try DeviceHelper(helper())
    let session = try await deviceHelper.connect(.keyboard, serial: serial, adb: adb)
    guard session.header.reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == version else {
      session.connection.close()
      throw ADBError.protocolFailure("Unsupported input helper version")
    }
    return Self(connection: session.connection)
  }

  func close() {
    connection.close()
  }

  func send(_ event: LivePreviewKeyboardEvent) async throws -> LivePreviewKeyboardResponse {
    let frame = try Self.frame(event)
    return try await perform {
      try connection.withRequestTimeout(.seconds(3)) {
        try connection.writeFully(frame)
        switch try DeviceClipboardProtocol.readNumber(connection) {
        case 0: return .sent
        case 1: return try .copied(DeviceClipboardProtocol.readText(connection))
        case 2: return .unsupportedText
        default: throw ADBError.protocolFailure("Device input failed")
        }
      }
    }
  }

  static func frame(_ event: LivePreviewKeyboardEvent) throws -> Data {
    func number(_ value: UInt32) -> Data {
      var value = value.bigEndian
      return withUnsafeBytes(of: &value) { Data($0) }
    }
    switch event {
    case .text(let text): return try number(1) + DeviceClipboardProtocol.frame(text)
    case .key(let code, let modifiers): return number(2) + number(code) + number(modifiers)
    case .paste(let text): return try number(3) + DeviceClipboardProtocol.frame(text)
    case .copy: return number(4)
    case .keyDown(let code): return number(5) + number(code)
    case .keyUp(let code): return number(6) + number(code)
    }
  }

  private func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
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

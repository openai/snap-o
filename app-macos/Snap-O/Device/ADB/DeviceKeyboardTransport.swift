import Foundation

enum DeviceKeyboardError: Error {
  case unsupportedText

  var message: String {
    "Use Paste for characters Android can’t type."
  }
}

struct DeviceKeyboardTransport: LivePreviewKeyboardTransport {
  static let version: UInt32 = 1
  let connection: ADBSocketConnection
  private let queue = DispatchQueue(label: "snapo.keyboard")

  static func connect(serial: String, adb: ADBClient = ADBClient()) async throws -> Self {
    guard let url = Bundle.main.url(forResource: "snapo-device-helper", withExtension: "jar") else {
      throw ADBError.protocolFailure("Missing device input helper")
    }
    let command = try DeviceClipboardProtocol.launchCommand(helper: Data(contentsOf: url), keyboard: true)
    let connection = try await adb.makeConnection()
    let transport = Self(connection: connection)
    do {
      try await transport.perform {
        try connection.withRequestTimeout(.seconds(8)) {
          try connection.sendTransport(to: serial)
          _ = try connection.sendHostCommand("exec:" + command, expectsResponse: false)
          guard try DeviceClipboardProtocol.readNumber(connection) == version else {
            throw ADBError.protocolFailure("Unsupported input helper version")
          }
        }
      }
      return transport
    } catch {
      connection.close()
      throw error
    }
  }

  func close() {
    connection.close()
  }

  func send(_ event: LivePreviewKeyboardEvent) async throws -> String? {
    let frame = try Self.frame(event)
    return try await perform {
      try connection.withRequestTimeout(.seconds(3)) {
        try connection.writeFully(frame)
        switch try DeviceClipboardProtocol.readNumber(connection) {
        case 0: return nil
        case 1: return try DeviceClipboardProtocol.readText(connection)
        case 2: throw DeviceKeyboardError.unsupportedText
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

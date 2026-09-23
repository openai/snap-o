import Foundation

struct DeviceClipboardTransport: ClipboardTransport {
  private let connection: ADBSocketConnection
  private let initialText: String
  private let reader = DispatchQueue(label: "snapo.clipboard.read")
  private let writer = DispatchQueue(label: "snapo.clipboard.write")

  static func connect(
    serial: String,
    adb: ADBClient = ADBClient(),
    isolation: isolated (any Actor)? = #isolation,
    body: (Self) async throws -> Void
  ) async throws {
    guard let url = Bundle.main.url(forResource: "snapo-device-helper", withExtension: "jar") else {
      throw ADBError.protocolFailure("Missing device clipboard helper")
    }
    let command = try DeviceClipboardProtocol.launchCommand(helper: Data(contentsOf: url))
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

enum DeviceClipboardProtocol {
  static func launchCommand(helper: Data, keyboard: Bool = false) throws -> String {
    guard !helper.isEmpty, helper.count <= 32768 else {
      throw ADBError.protocolFailure("Invalid clipboard helper")
    }
    // Each preview owns its temporary file and process; EOF stops the helper.
    return """
    directory=$(mktemp -d /data/local/tmp/snapo-clipboard.XXXXXX) || exit 1
    trap 'rm -f "$directory/helper.jar"; rmdir "$directory" 2>/dev/null' EXIT
    (umask 077; printf '%s' '\(helper.base64EncodedString())' | base64 -d > "$directory/helper.jar") &&
      chmod 444 "$directory/helper.jar" || exit 1
    CLASSPATH="$directory/helper.jar" app_process / com.openai.snapo.clipboard.Main "$directory"\(keyboard ? " keyboard" : "") 2>/dev/null
    """
  }

  static func frame(_ text: String) throws -> Data {
    let bytes = Data(text.utf8)
    guard bytes.count <= ClipboardSyncState.maximumTextBytes else {
      throw ADBError.protocolFailure("Clipboard text is too large")
    }
    var length = UInt32(bytes.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(bytes)
    return frame
  }

  static func readNumber(_ connection: ADBSocketConnection) throws -> UInt32 {
    try readExactly(4, connection: connection).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  static func readText(_ connection: ADBSocketConnection) throws -> String {
    let length = try readNumber(connection)
    guard length <= ClipboardSyncState.maximumTextBytes else {
      throw ADBError.protocolFailure("Clipboard text is too large")
    }
    guard let text = try String(data: readExactly(Int(length), connection: connection), encoding: .utf8) else {
      throw ADBError.protocolFailure("Invalid clipboard text")
    }
    return text
  }

  private static func readExactly(_ count: Int, connection: ADBSocketConnection) throws -> Data {
    var data = Data()
    while data.count < count {
      guard let chunk = try connection.readChunk(maxLength: count - data.count) else {
        throw ADBError.protocolFailure("Clipboard helper disconnected")
      }
      data.append(chunk)
    }
    return data
  }
}

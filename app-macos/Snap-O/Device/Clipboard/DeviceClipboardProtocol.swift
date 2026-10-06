import Foundation

enum DeviceClipboardProtocol {
  static func bundledHelper() throws -> Data {
    guard let url = Bundle.main.url(forResource: "snapo-device-helper", withExtension: "jar") else {
      throw ADBError.protocolFailure("Missing device input helper")
    }
    return try Data(contentsOf: url)
  }

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

  static func readNumber(_ connection: any ADBConnection) throws -> UInt32 {
    try readExactly(4, read: connection.readChunk).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  static func readText(_ connection: any ADBConnection) throws -> String {
    try readText(read: connection.readChunk)
  }

  static func readText(read: (Int) throws -> Data?) throws -> String {
    let length = try readExactly(4, read: read).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= ClipboardSyncState.maximumTextBytes else {
      throw ADBError.protocolFailure("Clipboard text is too large")
    }
    guard let text = try String(data: readExactly(Int(length), read: read), encoding: .utf8) else {
      throw ADBError.protocolFailure("Invalid clipboard text")
    }
    return text
  }

  private static func readExactly(_ count: Int, read: (Int) throws -> Data?) throws -> Data {
    var data = Data()
    while data.count < count {
      guard let chunk = try read(count - data.count) else {
        throw ADBError.protocolFailure("Clipboard helper disconnected")
      }
      data.append(chunk)
    }
    return data
  }
}

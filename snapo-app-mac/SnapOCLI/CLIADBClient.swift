import Foundation

struct CLIDevice {
  let id: String
}

struct CLIServerReference: Hashable {
  let deviceID: String
  let socketName: String

  var identifier: String {
    "\(deviceID)/\(socketName)"
  }
}

struct CLIServerAppInfo {
  let packageName: String?
  let appName: String?
}

struct CLIADBClient {
  func devices() throws -> [CLIDevice] {
    let connection = try ADBSocketConnection()
    defer { connection.close() }
    try connection.sendDevicesList()
    guard let payload = try connection.readLengthPrefixedPayload(),
          let output = String(data: payload, encoding: .utf8) else {
      return []
    }

    return output
      .split(separator: "\n")
      .compactMap { line -> CLIDevice? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        let state = fields[1].lowercased()
        guard state == "device" || state == "emulator" else { return nil }
        return CLIDevice(id: String(fields[0]))
      }
  }

  func shell(deviceID: String, command: String) throws -> String {
    let connection = try ADBSocketConnection()
    defer { connection.close() }
    try connection.sendTransport(to: deviceID)
    try connection.sendShell(command)
    let data = try connection.readToEnd()
    return String(data: data, encoding: .utf8) ?? ""
  }

  func networkSocketNames(deviceID: String) throws -> [String] {
    let output = try shell(deviceID: deviceID, command: "cat /proc/net/unix")
    return Array(
      Set(
        output
          .split(separator: "\n")
          .compactMap { $0.split(whereSeparator: \.isWhitespace).last }
          .compactMap { token -> String? in
            let name = String(token)
            guard name.hasPrefix("@snapo_network_") else { return nil }
            return String(name.dropFirst())
          }
      )
    ).sorted()
  }

  func packageNameHint(for server: CLIServerReference) -> String? {
    guard let pid = Self.pid(from: server.socketName),
          let output = try? shell(
            deviceID: server.deviceID,
            command: "cat /proc/\(pid)/cmdline 2>/dev/null"
          ) else {
      return nil
    }
    return output
      .split { $0 == "\0" || $0 == "\n" || $0 == "\r" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  static func pid(from socketName: String) -> Int? {
    let prefix = "snapo_network_"
    guard socketName.hasPrefix(prefix) else { return nil }
    return Int(socketName.dropFirst(prefix.count))
  }
}

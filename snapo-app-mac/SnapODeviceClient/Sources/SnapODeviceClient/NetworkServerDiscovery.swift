import Foundation

public enum NetworkServerDiscovery {
  public static let socketPrefix = "snapo_network_"

  public static func socketNames(inProcNetUnix output: String) -> [String] {
    Array(
      Set(
        output
          .split(separator: "\n")
          .compactMap { $0.split(whereSeparator: \.isWhitespace).last }
          .compactMap { token -> String? in
            let name = String(token)
            guard name.hasPrefix("@\(socketPrefix)") else { return nil }
            return String(name.dropFirst())
          }
      )
    ).sorted()
  }

  public static func pid(inSocketName socketName: String) -> Int? {
    guard socketName.hasPrefix(socketPrefix) else { return nil }
    return Int(socketName.dropFirst(socketPrefix.count))
  }

  public static func packageName(inCmdline output: String) -> String? {
    output
      .split { $0 == "\0" || $0 == "\n" || $0 == "\r" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  public static func connectedDeviceIDs(inDevicesList output: String) -> [String] {
    output
      .split(separator: "\n")
      .compactMap { line -> String? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        let state = fields[1].lowercased()
        guard state == "device" || state == "emulator" else { return nil }
        return String(fields[0])
      }
  }

  public static func discover(
    on deviceIDs: [String],
    using adb: ADBClient
  ) async -> [NetworkServerReference] {
    await withTaskGroup(of: [NetworkServerReference].self) { group in
      for deviceID in deviceIDs {
        group.addTask {
          guard let output = try? await adb.listUnixSockets(deviceID: deviceID) else {
            return []
          }
          return socketNames(inProcNetUnix: output).map {
            NetworkServerReference(deviceId: deviceID, socketName: $0)
          }
        }
      }

      var references: [NetworkServerReference] = []
      for await result in group {
        references.append(contentsOf: result)
      }
      return references.sorted {
        if $0.deviceId != $1.deviceId { return $0.deviceId < $1.deviceId }
        return $0.socketName < $1.socketName
      }
    }
  }

  public static func packageNameHint(
    for reference: NetworkServerReference,
    using adb: ADBClient
  ) async -> String? {
    guard let pid = pid(inSocketName: reference.socketName),
          let output = try? await adb.runShellString(
            deviceID: reference.deviceId,
            command: "cat /proc/\(pid)/cmdline 2>/dev/null"
          )
    else {
      return nil
    }
    return packageName(inCmdline: output)
  }
}

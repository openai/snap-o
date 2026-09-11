import Foundation

public enum DeviceDiscovery {
  public static func processNames(inProcessList output: String) -> [Int: String] {
    let lines = output.split(whereSeparator: \.isNewline)
    guard let header = lines.first?.split(whereSeparator: \.isWhitespace),
          let pidColumn = header.firstIndex(of: "PID"),
          let nameColumn = header.firstIndex(of: "NAME") else { return [:] }
    var names: [Int: String] = [:]
    for line in lines.dropFirst() {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count > max(pidColumn, nameColumn),
            let pid = Int(fields[pidColumn]), pid > 0 else { continue }
      names[pid] = String(fields[nameColumn])
    }
    return names
  }

  public static func processName(inCmdline output: String) -> String? {
    output
      .split { $0 == "\0" || $0 == "\n" || $0 == "\r" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  public static func androidUserID(inProcStatus output: String) -> Int? {
    guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Uid:") }),
          let value = line.split(whereSeparator: \.isWhitespace).dropFirst().first,
          let uid = UInt32(value) else { return nil }
    // Android assigns each user a range of 100,000 UIDs.
    return Int(uid / 100_000)
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

  public static func processName(
    deviceID: String,
    using adb: ADBClient,
    pid: Int
  ) async -> String? {
    guard pid > 0,
          let output = try? await adb.runDiscoveryShellString(
            deviceID: deviceID,
            command: "cat /proc/\(pid)/cmdline 2>/dev/null"
          )
    else {
      return nil
    }
    return processName(inCmdline: output)
  }

  public static func androidUserID(
    deviceID: String,
    using adb: ADBClient,
    pid: Int
  ) async -> Int? {
    guard pid > 0,
          let output = try? await adb.runDiscoveryShellString(
            deviceID: deviceID,
            command: "cat /proc/\(pid)/status 2>/dev/null"
          ) else { return nil }
    return androidUserID(inProcStatus: output)
  }
}

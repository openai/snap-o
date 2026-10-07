import Foundation

public extension DeviceDiscovery {
  static func processName(
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

  static func androidUserID(
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

public extension ToolDiscovery {
  static func discover(
    on devices: [Device],
    using adb: ADBClient
  ) async throws -> [DiscoveredPluginSocket] {
    try await withThrowingTaskGroup(of: Result<[DiscoveredPluginSocket], Error>.self) { group in
      for device in devices {
        let deviceID = device.id
        group.addTask {
          do {
            let target = try device.requireConnection()
            let output = try await adb.bound(to: target).runDiscoveryShellString(deviceID: target.serial, command: snapshotCommand)
            return .success(Self.sockets(inProcNetUnix: output, deviceID: deviceID))
          } catch {
            return .failure(error)
          }
        }
      }
      var sockets: [DiscoveredPluginSocket] = []
      var failure: Error?
      for try await result in group {
        switch result {
        case .success(let discovered): sockets.append(contentsOf: discovered)
        case .failure(let error): failure = error
        }
      }
      try Task.checkCancellation()
      // Keep healthy tools visible, but report an empty result only when every device was scanned.
      if sockets.isEmpty, let failure { throw failure }
      return sockets.sorted { $0.reference.identifier < $1.reference.identifier }
    }
  }
}

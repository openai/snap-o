import Foundation

struct ShowTouchesOverride {
  let deviceID: String
  fileprivate let id: UUID

  static func apply(
    deviceID: String,
    enabled: Bool,
    using adb: ADBService,
    timeout: Duration? = nil
  ) async -> ShowTouchesOverride {
    await TouchSettingLeases.shared.acquire(deviceID: deviceID, enabled: enabled, adb: adb, timeout: timeout)
  }

  func restore(using adb: ADBService, timeout: Duration? = nil) async {
    await TouchSettingLeases.shared.release(self, adb: adb, timeout: timeout)
  }
}

/// Restores the original setting only after both preview and recording release it.
private actor TouchSettingLeases {
  static let shared = TouchSettingLeases()
  private struct Entry {
    let originalValue: Task<Bool?, Never>
    var owners: Set<UUID>
  }

  private var entries: [String: Entry] = [:]
  private var cleanup: [String: Task<Void, Never>] = [:]

  func acquire(deviceID: String, enabled: Bool, adb: ADBService, timeout: Duration?) async -> ShowTouchesOverride {
    let lease = ShowTouchesOverride(deviceID: deviceID, id: UUID())
    if entries[deviceID] == nil {
      let previous = cleanup.removeValue(forKey: deviceID)
      let setup = Task {
        await previous?.value
        return await Self.apply(deviceID: deviceID, enabled: enabled, adb: adb, timeout: timeout)
      }
      entries[deviceID] = Entry(originalValue: setup, owners: [])
    }
    entries[deviceID]?.owners.insert(lease.id)
    _ = await entries[deviceID]?.originalValue.value
    return lease
  }

  func release(_ lease: ShowTouchesOverride, adb: ADBService, timeout: Duration?) async {
    guard var entry = entries[lease.deviceID], entry.owners.remove(lease.id) != nil else { return }
    guard entry.owners.isEmpty else {
      entries[lease.deviceID] = entry
      return
    }
    entries.removeValue(forKey: lease.deviceID)
    let task = Task {
      guard let original = await entry.originalValue.value else { return }
      await Self.write(original, deviceID: lease.deviceID, adb: adb, timeout: timeout)
    }
    cleanup[lease.deviceID] = task
    await task.value
  }

  private static func apply(deviceID: String, enabled: Bool, adb: ADBService, timeout: Duration?) async -> Bool? {
    #if PERF_TRACING
    let timing = Perf.startupBegin("touch settings setup", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let original: Bool
    do {
      original = try await adb.exec().withTimeout(timeout).getShowTouches(deviceID: deviceID)
    } catch {
      logFailure(action: "read", deviceID: deviceID, error: error)
      return nil
    }
    guard original != enabled else { return nil }
    await write(enabled, deviceID: deviceID, adb: adb, timeout: timeout)
    return original
  }

  private static func write(_ value: Bool, deviceID: String, adb: ADBService, timeout: Duration?) async {
    do {
      try await adb.exec().withTimeout(timeout).setShowTouches(deviceID: deviceID, enabled: value)
    } catch {
      logFailure(action: "write", deviceID: deviceID, error: error)
    }
  }

  private static func logFailure(action: String, deviceID: String, error: Error) {
    SnapOLog.recording.error(
      """
      Failed to \(action) show touches for \(deviceID, privacy: .private):
      \(error.localizedDescription, privacy: .public)
      """
    )
  }
}

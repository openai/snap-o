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
  private static let commandTimeout: Duration = .seconds(3)
  private struct Entry {
    var originalValue: Task<Bool?, Never>
    var enabled: Bool
    // A failed update may have applied partially, so restore after any preference change.
    var hasUpdatedPreference = false
    var owners: Set<UUID>
  }

  private var entries: [String: Entry] = [:]
  private var cleanup: [String: Task<Void, Never>] = [:]

  func acquire(deviceID: String, enabled: Bool, adb: ADBService, timeout: Duration?) async -> ShowTouchesOverride {
    let lease = ShowTouchesOverride(deviceID: deviceID, id: UUID())
    guard !Task.isCancelled else { return lease }
    if entries[deviceID] == nil {
      let previous = cleanup.removeValue(forKey: deviceID)
      let setup = Task {
        await previous?.value
        return await Self.apply(deviceID: deviceID, enabled: enabled, adb: adb)
      }
      entries[deviceID] = Entry(originalValue: setup, enabled: enabled, owners: [])
    }
    if var entry = entries[deviceID], entry.enabled != enabled {
      let previous = entry.originalValue
      entry.originalValue = Task {
        guard let original = await previous.value else { return nil }
        await Self.write(enabled, deviceID: deviceID, adb: adb)
        return original
      }
      entry.enabled = enabled
      entry.hasUpdatedPreference = true
      entries[deviceID] = entry
    }
    entries[deviceID]?.owners.insert(lease.id)
    if let task = entries[deviceID]?.originalValue,
       await !(Self.wait(for: task, timeout: timeout ?? Self.commandTimeout)) {
      _ = releaseTask(lease, adb: adb)
    }
    return lease
  }

  func release(_ lease: ShowTouchesOverride, adb: ADBService, timeout: Duration?) async {
    guard let task = releaseTask(lease, adb: adb) else { return }
    _ = await Self.wait(for: task, timeout: timeout ?? Self.commandTimeout)
  }

  private func releaseTask(_ lease: ShowTouchesOverride, adb: ADBService) -> Task<Void, Never>? {
    guard var entry = entries[lease.deviceID], entry.owners.remove(lease.id) != nil else { return nil }
    guard entry.owners.isEmpty else {
      entries[lease.deviceID] = entry
      return nil
    }
    entries.removeValue(forKey: lease.deviceID)
    let task = Task {
      guard let original = await entry.originalValue.value, original != entry.enabled || entry.hasUpdatedPreference else { return }
      await Self.write(original, deviceID: lease.deviceID, adb: adb)
    }
    cleanup[lease.deviceID] = task
    return task
  }

  private static func apply(deviceID: String, enabled: Bool, adb: ADBService) async -> Bool? {
    #if PERF_TRACING
    let timing = Perf.startupBegin("touch settings setup", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let original: Bool
    do {
      original = try await adb.exec().withTimeout(commandTimeout).getShowTouches(deviceID: deviceID)
    } catch {
      logFailure(action: "read", deviceID: deviceID, error: error)
      return nil
    }
    guard original != enabled else { return original }
    await write(enabled, deviceID: deviceID, adb: adb)
    return original
  }

  private static func write(_ value: Bool, deviceID: String, adb: ADBService) async {
    do {
      try await adb.exec().withTimeout(commandTimeout).setShowTouches(deviceID: deviceID, enabled: value)
    } catch {
      logFailure(action: "write", deviceID: deviceID, error: error)
    }
  }

  /// Ending a caller's wait must not cancel work shared with another capture.
  private static func wait(for task: Task<some Sendable, Never>, timeout: Duration) async -> Bool {
    guard !Task.isCancelled else { return false }
    let completion = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observer = Task {
      _ = await task.value
      completion.continuation.yield(true)
      completion.continuation.finish()
    }
    let timer = Task {
      do { try await Task.sleep(for: timeout) } catch { return }
      completion.continuation.yield(false)
      completion.continuation.finish()
    }
    defer {
      timer.cancel()
      observer.cancel()
      completion.continuation.finish()
    }
    for await completed in completion.stream {
      return completed && !Task.isCancelled
    }
    return false
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

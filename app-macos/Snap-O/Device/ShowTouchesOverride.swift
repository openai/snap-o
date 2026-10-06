import Dependencies
import Foundation

struct ShowTouchesOverride {
  fileprivate let target: DeviceTarget?
  fileprivate let id: UUID

  static func apply(
    target: DeviceTarget?,
    enabled: Bool,
    using adb: ADBService
  ) async -> ShowTouchesOverride {
    await TouchSettingLeases.shared.acquire(target: target, enabled: enabled, adb: adb)
  }

  func setEnabled(_ enabled: Bool, using adb: ADBService) async {
    await TouchSettingLeases.shared.update(self, enabled: enabled, adb: adb)
  }

  func restore(
    using adb: ADBService
  ) async {
    await TouchSettingLeases.shared.release(self, adb: adb)
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

  private var entries: [DeviceTarget: Entry] = [:]
  private var cleanup: [DeviceTarget: (id: UUID, task: Task<Void, Never>)] = [:]
  // Retain each release while a new acquisition takes over the target's cleanup chain.
  private var restorations: [UUID: Task<Void, Never>] = [:]

  func acquire(
    target: DeviceTarget?, enabled: Bool, adb: ADBService
  ) async -> ShowTouchesOverride {
    let lease = ShowTouchesOverride(target: target, id: UUID())
    guard !Task.isCancelled, let target, target.isValid else { return lease }
    if entries[target] == nil {
      let previous = cleanup.removeValue(forKey: target)
      let setup = Task {
        await previous?.task.value
        return await Self.apply(target: target, enabled: enabled, adb: adb)
      }
      entries[target] = Entry(originalValue: setup, enabled: enabled, owners: [])
    }
    updatePreference(target: target, enabled: enabled, adb: adb)
    entries[target]?.owners.insert(lease.id)
    if let task = entries[target]?.originalValue,
       await !(Self.wait(for: task)) {
      _ = releaseTask(lease, adb: adb)
    }
    return lease
  }

  func update(_ lease: ShowTouchesOverride, enabled: Bool, adb: ADBService) async {
    guard !Task.isCancelled, let target = lease.target, target.isValid,
          entries[target]?.owners.contains(lease.id) == true else { return }
    updatePreference(target: target, enabled: enabled, adb: adb)
    _ = await entries[target]?.originalValue.value
  }

  private func updatePreference(target: DeviceTarget, enabled: Bool, adb: ADBService) {
    if var entry = entries[target], entry.enabled != enabled {
      let previous = entry.originalValue
      entry.originalValue = Task {
        guard let original = await previous.value else { return nil }
        await Self.write(enabled, target: target, adb: adb)
        return original
      }
      entry.enabled = enabled
      entry.hasUpdatedPreference = true
      entries[target] = entry
    }
  }

  func release(
    _ lease: ShowTouchesOverride, adb: ADBService
  ) async {
    guard let task = releaseTask(lease, adb: adb) else { return }
    await task.value
  }

  private func releaseTask(_ lease: ShowTouchesOverride, adb: ADBService) -> Task<Void, Never>? {
    if let task = restorations[lease.id] { return task }
    guard let target = lease.target, var entry = entries[target], entry.owners.remove(lease.id) != nil else { return nil }
    guard entry.owners.isEmpty else {
      entries[target] = entry
      return nil
    }
    entries.removeValue(forKey: target)
    let cleanupID = UUID()
    let task = Task {
      if let original = await entry.originalValue.value, original != entry.enabled || entry.hasUpdatedPreference {
        await Self.write(original, target: target, adb: adb)
      }
      if cleanup[target]?.id == cleanupID { cleanup.removeValue(forKey: target) }
      restorations.removeValue(forKey: lease.id)
    }
    cleanup[target] = (cleanupID, task)
    restorations[lease.id] = task
    return task
  }

  private static func apply(target: DeviceTarget, enabled: Bool, adb: ADBService) async -> Bool? {
    let deviceID = target.serial
    #if PERF_TRACING
    let timing = Perf.startupBegin("touch settings setup", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let original: Bool
    do {
      original = try await adb.exec().bound(to: target).withTimeout(commandTimeout).getShowTouches(deviceID: deviceID)
    } catch {
      logFailure(action: "read", deviceID: deviceID, error: error)
      return nil
    }
    guard original != enabled else { return original }
    await write(enabled, target: target, adb: adb)
    return original
  }

  private static func write(_ value: Bool, target: DeviceTarget, adb: ADBService) async {
    guard target.isValid else { return }
    let deviceID = target.serial
    do {
      try await adb.exec().bound(to: target).withTimeout(commandTimeout).setShowTouches(deviceID: deviceID, enabled: value)
    } catch {
      logFailure(action: "write", deviceID: deviceID, error: error)
    }
  }

  /// Ending a caller's wait must not cancel work shared with another capture.
  private static func wait(
    for task: Task<some Sendable, Never>
  ) async -> Bool {
    guard !Task.isCancelled else { return false }
    let completion = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observer = Task {
      _ = await task.value
      completion.continuation.yield(true)
      completion.continuation.finish()
    }
    @Dependency(\.continuousClock)
    var clock
    let timer = Task { [clock] in
      do { try await clock.sleep(for: commandTimeout) } catch { return }
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

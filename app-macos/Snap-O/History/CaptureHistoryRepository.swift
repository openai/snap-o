import Foundation

/// Serializes history writes and cleanup away from the UI thread.
actor CaptureHistoryRepository {
  nonisolated let root: URL

  private var entries: [CaptureHistoryEntry] = []
  private var retention = CaptureHistoryRetention()
  private var errorMessage: String?
  private var loaded = false
  private var protections: [UUID: Set<UUID>] = [:]
  private var observers: [UUID: AsyncStream<CaptureHistorySnapshot>.Continuation] = [:]
  private let manager = FileManager.default

  init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Snap-O/Capture History", isDirectory: true)) {
    self.root = root
  }

  func updates() -> AsyncStream<CaptureHistorySnapshot> {
    loadIfNeeded()
    let id = UUID()
    let (stream, continuation) = AsyncStream<CaptureHistorySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    observers[id] = continuation
    continuation.yield(snapshot)
    continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
    return stream
  }

  func currentSnapshot() -> CaptureHistorySnapshot {
    loadIfNeeded()
    return snapshot
  }

  func begin(kind: CaptureHistoryEntry.Kind, devices: [Device], at date: Date = Date()) -> UUID? {
    loadIfNeeded()
    guard !devices.isEmpty else { return nil }
    var seen = Set<String>()
    let entry = CaptureHistoryEntry(
      id: UUID(), kind: kind, capturedAt: date,
      items: devices.filter { seen.insert($0.id).inserted }.map {
        CaptureHistoryEntry.Item(id: UUID(), deviceID: $0.id, deviceName: $0.displayTitle)
      }
    )
    do {
      try save(entry)
      entries.append(entry)
      publish()
      return entry.id
    } catch {
      report(error)
      return nil
    }
  }

  func record(_ capture: CaptureMedia, in entryID: UUID?, moveOriginal: Bool = true) -> CaptureMedia {
    guard let entryID, let index = entries.firstIndex(where: { $0.id == entryID }),
          let itemIndex = entries[index].items.firstIndex(where: { $0.deviceID == capture.device.id }),
          let source = capture.media.url else { return capture }
    var entry = entries[index]
    var item = entry.items[itemIndex]
    guard item.captureID == nil else { return capture }
    let destination = entry.fileURL(for: item, in: root)
    let staging = destination.appendingPathExtension("partial")
    do {
      item.captureID = capture.id
      item.width = capture.media.size.width
      item.height = capture.media.size.height
      item.densityScale = capture.media.densityScale.map(Double.init)
      item.byteCount = try Int64(source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      item.failure = nil
      entry.items[itemIndex] = item
      // Persist metadata first so a completed file can be recovered after interruption.
      try save(entry)
      try manager.copyItem(at: source, to: staging)
      try manager.moveItem(at: staging, to: destination)
      entries[index] = entry
      if moveOriginal { try? manager.removeItem(at: source) }
      publish()
      let media: Media = entry.kind == .image
        ? .image(url: destination, data: capture.media.common)
        : .video(url: destination, data: capture.media.common)
      return CaptureMedia(id: capture.id, device: capture.device, media: media)
    } catch {
      try? manager.removeItem(at: staging)
      try? save(entries[index])
      report(error)
      return capture
    }
  }

  func recordFailure(deviceID: String, message: String, in entryID: UUID?) {
    guard let entryID, let index = entries.firstIndex(where: { $0.id == entryID }),
          let itemIndex = entries[index].items.firstIndex(where: { $0.deviceID == deviceID }) else { return }
    var entry = entries[index]
    entry.items[itemIndex].failure = message
    persist(entry, at: index)
  }

  func finish(_ entryID: UUID?, at date: Date = Date()) {
    guard let entryID, let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
    var entry = entries[index]
    entry.completedAt = date
    for itemIndex in entry.items.indices where entry.items[itemIndex].captureID == nil {
      if entry.items[itemIndex].failure == nil {
        entry.items[itemIndex].failure = "Capture did not complete."
      }
    }
    persist(entry, at: index)
    prune(now: date)
  }

  func discardEmpty(_ entryID: UUID?) {
    guard let entryID, let entry = entries.first(where: { $0.id == entryID }),
          entry.items.allSatisfy({ $0.captureID == nil }) else { return }
    remove([entryID])
  }

  func rename(_ entryID: UUID, to name: String) {
    loadIfNeeded()
    guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var entry = entries[index]
    entry.name = trimmed.isEmpty ? nil : trimmed
    guard entry != entries[index] else { return }
    persist(entry, at: index)
  }

  func recordCapturePaneSelection(_ captureID: UUID) {
    guard !Task.isCancelled,
          let index = entries.firstIndex(where: { $0.items.contains { $0.captureID == captureID } }),
          let item = entries[index].availableItems.first(where: { $0.captureID == captureID }),
          entries[index].capturePaneSelectionID != item.id else { return }
    var entry = entries[index]
    entry.capturePaneSelectionID = item.id
    persist(entry, at: index)
  }

  func moveItem(_ itemID: UUID, to targetID: UUID, afterTarget: Bool, in entryID: UUID) {
    guard itemID != targetID,
          let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
    var entry = entries[index]
    let originalOrder = entry.orderedItems
    guard let sourceIndex = originalOrder.firstIndex(where: { $0.id == itemID }),
          let targetIndex = originalOrder.firstIndex(where: { $0.id == targetID }) else { return }
    entry.items = originalOrder
    let item = entry.items.remove(at: sourceIndex)
    let destination = targetIndex - (sourceIndex < targetIndex ? 1 : 0) + (afterTarget ? 1 : 0)
    entry.items.insert(item, at: destination)
    guard entry.items != originalOrder else { return }
    entry.capturePaneSelectionID = entry.items.first(where: \.isAvailable)?.id
    persist(entry, at: index)
  }

  func protect(_ captureIDs: Set<UUID>, owner: UUID) {
    guard !Task.isCancelled else { return }
    protections[owner] = captureIDs.isEmpty ? nil : captureIDs
  }

  func cleanupCandidates(
    using policy: CaptureHistoryRetention? = nil,
    now: Date = Date()
  ) -> [CaptureHistoryEntry] {
    loadIfNeeded()
    let policy = policy ?? retention
    let protectedIDs = protections.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    let newest = entries.max { $0.capturedAt < $1.capturedAt }?.id
    let oldestFirst = entries.sorted { $0.capturedAt < $1.capturedAt }
    let eligible = oldestFirst.filter { entry in
      guard let completedAt = entry.completedAt,
            !entry.items.contains(where: { $0.captureID.map(protectedIDs.contains) == true }) else { return false }
      let age = now.timeIntervalSince(completedAt)
      // Allow the capture service to hand a new result to its window before pruning it.
      guard age >= 60 else { return false }
      return !(entry.id == newest && entry.byteCount > policy.limitBytes && age < 24 * 60 * 60)
    }
    var removed = eligible.filter {
      now.timeIntervalSince($0.completedAt ?? now) >= Double(policy.days) * 24 * 60 * 60
    }
    let expiredIDs = Set(removed.map(\.id))
    var bytes = entries.reduce(Int64(0)) { $0 + $1.byteCount } - removed.reduce(Int64(0)) { $0 + $1.byteCount }
    for entry in eligible where !expiredIDs.contains(entry.id) && bytes > policy.limitBytes {
      removed.append(entry)
      bytes -= entry.byteCount
    }
    return removed
  }

  func prune(now: Date = Date()) {
    remove(cleanupCandidates(now: now).map(\.id))
  }

  func setRetention(_ policy: CaptureHistoryRetention) {
    guard policy.isValid else { return }
    do {
      try JSONEncoder().encode(policy).write(to: root.appendingPathComponent("retention.json"), options: .atomic)
      retention = policy
      prune()
      publish()
    } catch { report(error) }
  }

  func delete(_ ids: Set<UUID>, excludingOwner: UUID? = nil) {
    let protectedIDs = protections.filter { $0.key != excludingOwner }
      .values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    let eligible = entries.filter { entry in
      ids.contains(entry.id) && entry.completedAt != nil
        && !entry.items.contains { $0.captureID.map(protectedIDs.contains) == true }
    }
    remove(eligible.map(\.id))
    if eligible.count < ids.count {
      errorMessage = "Some captures are still in use. Close their viewers and try again."
      publish()
    }
  }

  func clearError() {
    errorMessage = nil
    publish()
  }

  private var snapshot: CaptureHistorySnapshot {
    CaptureHistorySnapshot(
      entries: entries.sorted { $0.capturedAt > $1.capturedAt },
      retention: retention, errorMessage: errorMessage
    )
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    do {
      try manager.createDirectory(at: root, withIntermediateDirectories: true)
      if let data = try? Data(contentsOf: root.appendingPathComponent("retention.json")),
         let saved = try? JSONDecoder().decode(CaptureHistoryRetention.self, from: data), saved.isValid {
        retention = saved
      }
      for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
        guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
        do {
          let data = try Data(contentsOf: directory.appendingPathComponent("capture.json"))
          var entry = try JSONDecoder().decode(CaptureHistoryEntry.self, from: data)
          guard entry.id == id else { continue }
          let wasInterrupted = entry.completedAt == nil
          for index in entry.items.indices {
            let item = entry.items[index]
            try? manager.removeItem(at: entry.fileURL(for: item, in: root).appendingPathExtension("partial"))
            if item.captureID != nil, !manager.fileExists(atPath: entry.fileURL(for: item, in: root).path) {
              entry.items[index].failure = "The original file is unavailable."
              entry.items[index].byteCount = 0
            } else if item.captureID == nil, item.failure == nil {
              entry.items[index].failure = "Capture was interrupted."
            }
          }
          if wasInterrupted { entry.completedAt = entry.capturedAt }
          try save(entry)
          entries.append(entry)
        } catch { report(error) }
      }
    } catch { report(error) }
  }

  private func save(_ entry: CaptureHistoryEntry) throws {
    let directory = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
  }

  private func persist(_ entry: CaptureHistoryEntry, at index: Int) {
    do {
      try save(entry)
      entries[index] = entry
      publish()
    } catch { report(error) }
  }

  private func remove(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    for id in ids {
      do {
        try manager.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
        entries.removeAll { $0.id == id }
      } catch { report(error) }
    }
    publish()
  }

  private func publish() {
    let snapshot = snapshot
    for observer in observers.values {
      observer.yield(snapshot)
    }
  }

  private func report(_ error: Error) {
    errorMessage = "Could not update capture history: \(error.localizedDescription)"
    publish()
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}

import AppKit
import UniformTypeIdentifiers

private let firstDevice = Device(
  id: "device-a",
  model: "Device A",
  androidVersion: "16",
  vendorModel: nil,
  manufacturer: nil,
  avdName: nil
)
private let secondDevice = Device(
  id: "device-b",
  model: "Device B",
  androidVersion: "16",
  vendorModel: nil,
  manufacturer: nil,
  avdName: nil
)

@main
struct CaptureHistoryTests {
  static func main() async throws {
    try await naming()
    try await persistenceAndSelection()
    try await reordering()
    try await rememberedDisplayOrder()
    try await dragRepresentations()
    nativeDropLifecycle()
    nativeDropBelowLastRow()
    try retentionPreferences()
    try await retentionAndProtection()
    try await oversizedGrace()
    try await failureAndRecovery()
    try await screenshotCancellation()
    print("Capture history tests passed")
  }

  static func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func capture(device: Device, bytes: Int = 100, in directory: URL) throws -> CaptureMedia {
    let url = directory.appendingPathComponent("\(UUID().uuidString).png")
    try Data(repeating: 7, count: bytes).write(to: url)
    return CaptureMedia(device: device, media: .image(
      url: url,
      capturedAt: Date(),
      display: DisplayInfo(size: CGSize(width: 100, height: 200), densityScale: 2)
    ))
  }

  static func screenshotCancellation() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for keepsCompletedScreenshot in [false, true] {
      let directory = root.appendingPathComponent(UUID().uuidString)
      let repository = CaptureHistoryRepository(root: directory.appendingPathComponent("history"))
      let adb = ADBService()
      let service = ScreenshotService(
        adb: adb,
        fileStore: FileStore(baseDir: directory.appendingPathComponent("temporary")),
        history: repository
      )
      let devices = keepsCompletedScreenshot ? [firstDevice, secondDevice] : [secondDevice]
      let task = Task { await service.capture(for: devices) }
      var ready = false
      for _ in 0 ..< 2000 {
        let snapshot = await repository.currentSnapshot()
        let hasExpectedMedia = !keepsCompletedScreenshot || snapshot.entries.first?.availableItems.count == 1
        if await adb.waitingForCancellation, hasExpectedMedia {
          ready = true
          break
        }
        try await Task.sleep(for: .milliseconds(1))
      }
      precondition(ready, "Reach the intended cancellation point before canceling")
      task.cancel()
      let result = await task.value
      let snapshot = await CaptureHistoryRepository(root: repository.root).currentSnapshot()
      if keepsCompletedScreenshot {
        precondition(result.media.count == 1 && snapshot.entries.count == 1)
        precondition(snapshot.entries[0].availableItems.count == 1)
        precondition(snapshot.entries[0].completedAt != nil)
        precondition(FileManager.default.fileExists(atPath: result.media[0].media.url!.path))
        precondition(snapshot.entries[0].items[1].failure == "Capture did not complete.")
      } else {
        precondition(result.media.isEmpty && snapshot.entries.isEmpty, "Canceled empty captures leave no history entry")
      }
    }

    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("failed-history"))
    let service = ScreenshotService(
      adb: ADBService(),
      fileStore: FileStore(baseDir: root.appendingPathComponent("failed-temporary")),
      history: repository
    )
    let device = Device(
      id: "failed-device",
      model: "Failed Device",
      androidVersion: "16",
      vendorModel: nil,
      manufacturer: nil,
      avdName: nil
    )
    let result = await service.capture(for: [device])
    let snapshot = await repository.currentSnapshot()
    precondition(result.failures.count == 1 && snapshot.entries.count == 1, "Genuine failures remain in history")
    precondition(snapshot.entries[0].items[0].failure == ADBError.protocolFailure("Screenshot failed").localizedDescription)
  }

  static func persistenceAndSelection() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let id = await repository.begin(kind: .image, devices: [firstDevice, secondDevice])!
    let sourceA = try capture(device: firstDevice, in: root)
    let sourceB = try capture(device: secondDevice, in: root)
    let storedB = await repository.record(sourceB, in: id)
    let storedA = await repository.record(sourceA, in: id)
    await repository.finish(id)
    var snapshot = await repository.currentSnapshot()
    precondition(snapshot.entries.count == 1)
    precondition(snapshot.entries[0].availableItems.count == 2)
    precondition(storedA.id == sourceA.id && storedB.id == sourceB.id)
    precondition(storedA.media.url != sourceA.media.url)
    precondition(!FileManager.default.fileExists(atPath: sourceA.media.url!.path))
    precondition(FileManager.default.fileExists(atPath: storedA.media.url!.path))
    precondition(
      snapshot.entries[0].frontItem?.captureID == storedA.id,
      "Use the first capture in list order, regardless of completion order"
    )
    let selectedID = snapshot.entries[0].items[1].id
    await repository.recordCapturePaneSelection(storedB.id)
    let reopened = CaptureHistoryRepository(root: repository.root)
    snapshot = await reopened.currentSnapshot()
    precondition(snapshot.entries[0].frontItem?.id == selectedID)
    precondition(snapshot.entries[0].byteCount == 200)
    let export = root.appendingPathComponent("export.png")
    try FileManager.default.copyItem(at: storedA.media.url!, to: export)
    await reopened.delete([id])
    precondition(FileManager.default.fileExists(atPath: export.path))
    precondition(!FileManager.default.fileExists(atPath: storedA.media.url!.path))
  }

  static func naming() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let id = await repository.begin(kind: .image, devices: [firstDevice, secondDevice])!
    await repository.rename(id, to: "  Login flow  ")
    let first = try await repository.record(capture(device: firstDevice, in: root), in: id)
    _ = try await repository.record(capture(device: secondDevice, in: root), in: id)
    await repository.finish(id)
    await repository.recordCapturePaneSelection(first.id)
    let original = await repository.currentSnapshot().entries[0]
    precondition(original.displayName == "Login flow", "Completing a capture preserves its name")

    let reopened = CaptureHistoryRepository(root: repository.root)
    let saved = await reopened.currentSnapshot().entries[0]
    precondition(saved == original, "Names and device metadata survive reopening")
    let updates = await reopened.updates()
    var iterator = updates.makeAsyncIterator()
    _ = await iterator.next()
    await reopened.rename(id, to: "Checkout")
    let renamed = await iterator.next()!.entries[0]
    precondition(renamed.displayName == "Checkout", "Renaming publishes to other windows")
    precondition(renamed.items == saved.items && renamed.capturedAt == saved.capturedAt)
    for item in renamed.items {
      precondition(FileManager.default.fileExists(atPath: renamed.fileURL(for: item, in: repository.root).path))
    }
    await reopened.rename(id, to: " \n ")
    let cleared = await CaptureHistoryRepository(root: repository.root).currentSnapshot().entries[0]
    precondition(cleared.name == nil && cleared.displayName == "Untitled")

    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
    legacy.removeValue(forKey: "name")
    let decoded = try JSONDecoder().decode(CaptureHistoryEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
    precondition(decoded.name == nil && decoded.displayName == "Untitled", "Existing history needs no migration")
    precondition(decoded.items == saved.items)
    let nextID = await reopened.begin(kind: .video, devices: [firstDevice])!
    let next = await reopened.currentSnapshot().entries.first { $0.id == nextID }!
    precondition(next.displayName == "Untitled", "A new capture does not inherit the last name")
  }

  static func reordering() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let id = await repository.begin(kind: .image, devices: [firstDevice, secondDevice])!
    let first = try await repository.record(capture(device: firstDevice, in: root), in: id)
    _ = try await repository.record(capture(device: secondDevice, in: root), in: id)
    await repository.finish(id)
    await repository.recordCapturePaneSelection(first.id)
    let original = await repository.currentSnapshot().entries[0]
    await repository.moveItem(original.items[0].id, to: original.items[1].id, afterTarget: true, in: id)
    let reopened = CaptureHistoryRepository(root: repository.root)
    let reordered = await reopened.currentSnapshot().entries[0]
    precondition(reordered.items.map(\.id) == original.items.reversed().map(\.id))
    precondition(reordered.capturePaneSelectionID == reordered.items[0].id)
    precondition(reordered.frontItem?.id == original.items[1].id, "Reordering remembers the new first image")
    precondition(reordered.capturedAt == original.capturedAt && reordered.completedAt == original.completedAt)
    for item in reordered.items {
      precondition(FileManager.default.fileExists(atPath: reordered.fileURL(for: item, in: repository.root).path))
    }
    await reopened.moveItem(reordered.items[0].id, to: UUID(), afterTarget: false, in: id)
    await reopened.moveItem(UUID(), to: reordered.items[0].id, afterTarget: false, in: id)
    await reopened.moveItem(reordered.items[0].id, to: reordered.items[1].id, afterTarget: false, in: id)
    let unchanged = await reopened.currentSnapshot().entries[0]
    precondition(unchanged == reordered, "Unknown or cross-capture item IDs cannot change the order")
    await reopened.moveItem(reordered.items[1].id, to: reordered.items[0].id, afterTarget: false, in: id)
    let restored = await reopened.currentSnapshot().entries[0]
    precondition(restored.items == original.items, "Reordering works in both directions")
    precondition(restored.frontItem?.captureID == first.id)
  }

  static func rememberedDisplayOrder() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let thirdDevice = Device(
      id: "device-c",
      model: "Device C",
      androidVersion: "16",
      vendorModel: nil,
      manufacturer: nil,
      avdName: nil
    )
    let id = await repository.begin(kind: .image, devices: [firstDevice, secondDevice, thirdDevice])!
    for device in [firstDevice, secondDevice, thirdDevice] {
      _ = try await repository.record(capture(device: device, in: root), in: id)
    }
    await repository.finish(id)
    let original = await repository.currentSnapshot().entries[0]
    let ids = original.items.map(\.id)
    await repository.recordCapturePaneSelection(original.items[2].captureID!)
    let selected = await repository.currentSnapshot().entries[0]
    precondition(selected.orderedItems.map(\.id) == [ids[2], ids[0], ids[1]])
    precondition(
      selected.availableItems.map(\.id) == selected.orderedItems.map(\.id),
      "Stack, expanded screens, and navigation share the remembered order"
    )
    await repository.moveItem(ids[2], to: ids[0], afterTarget: false, in: id)
    let unchanged = await repository.currentSnapshot().entries[0]
    precondition(
      unchanged == selected,
      "Dropping at the current displayed position is a no-op"
    )
    await repository.moveItem(ids[1], to: ids[0], afterTarget: false, in: id)
    let reordered = await repository.currentSnapshot().entries[0]
    precondition(
      reordered.orderedItems.map(\.id) == [ids[2], ids[1], ids[0]],
      "Reorder the visible sequence without moving the remembered front unexpectedly"
    )
    await repository.moveItem(ids[2], to: ids[0], afterTarget: true, in: id)
    let reopened = CaptureHistoryRepository(root: repository.root)
    let persisted = await reopened.currentSnapshot().entries[0]
    precondition(persisted.orderedItems.map(\.id) == [ids[1], ids[0], ids[2]])
    precondition(persisted.frontItem?.id == ids[1])
  }

  static func dragRepresentations() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for kind in [CaptureHistoryEntry.Kind.image, .video] {
      let url = root.appendingPathComponent("export.\(kind.fileExtension)")
      let bytes = Data([1, 2, 3, 4])
      try bytes.write(to: url)
      let media = CaptureHistoryDraggedMedia(entryID: UUID(), itemID: UUID(), url: url)
      let provider = media.provider(kind: kind)
      let type = kind == .image ? UTType.png : UTType.mpeg4Movie
      precondition(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
      precondition(provider.suggestedName == url.lastPathComponent)
      let droppedURL: URL = try await withCheckedThrowingContinuation { continuation in
        provider.loadObject(ofClass: NSURL.self) { object, error in
          if let url = object as? URL { continuation.resume(returning: url) }
          else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
        }
      }
      precondition(droppedURL == media.url, "External drops can request the exported file URL")
      let exported: Data = try await withCheckedThrowingContinuation { continuation in
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { file, error in
          do {
            guard let file else { throw error ?? CocoaError(.fileReadUnknown) }
            try continuation.resume(returning: Data(contentsOf: file))
          } catch { continuation.resume(throwing: error) }
        }
      }
      precondition(exported == bytes, "External drops receive the actual media file")
    }
  }

  @MainActor
  static func nativeDropLifecycle() {
    _ = NSApplication.shared
    let view = CaptureHistoryDropView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let info = HistoryTestDraggingInfo()
    defer { info.draggingPasteboard.releaseGlobally() }
    let sourceID = UUID()
    let targetID = UUID()
    let otherTargetID = UUID()
    var hint: CaptureHistoryInsertion?
    var dropped: CaptureHistoryInsertion?
    view.sourceID = sourceID
    view.targets = [
      targetID: CGRect(x: 0, y: 0, width: 200, height: 100),
      otherTargetID: CGRect(x: 300, y: 0, width: 200, height: 100),
      sourceID: CGRect(x: 600, y: 0, width: 200, height: 100)
    ]
    view.updateHint = { hint = $0 }
    view.performDrop = { dropped = $0 }
    info.draggingLocation = view.convert(NSPoint(x: 220, y: 50), to: nil)
    precondition(view.draggingEntered(info).isEmpty, "Empty space needs a prior insertion point")
    precondition(!view.prepareForDragOperation(info))
    info.draggingLocation = view.convert(NSPoint(x: 20, y: 50), to: nil)
    precondition(view.draggingUpdated(info) == .move)
    precondition(hint == CaptureHistoryInsertion(itemID: targetID, afterTarget: false))
    info.draggingLocation = view.convert(NSPoint(x: 180, y: 50), to: nil)
    precondition(view.draggingUpdated(info) == .move)
    precondition(hint == CaptureHistoryInsertion(itemID: targetID, afterTarget: true))
    info.draggingLocation = view.convert(NSPoint(x: 220, y: 50), to: nil)
    precondition(view.draggingUpdated(info) == .move)
    precondition(hint == CaptureHistoryInsertion(itemID: targetID, afterTarget: true), "Keep the hint beyond thumbnail bounds")
    info.draggingLocation = view.convert(NSPoint(x: 320, y: 50), to: nil)
    precondition(view.draggingUpdated(info) == .move)
    precondition(hint == CaptureHistoryInsertion(itemID: otherTargetID, afterTarget: false), "Crossing a new thumbnail replaces the hint")
    info.draggingLocation = view.convert(NSPoint(x: 620, y: 50), to: nil)
    precondition(view.draggingUpdated(info) == .move)
    precondition(
      hint == CaptureHistoryInsertion(itemID: otherTargetID, afterTarget: false),
      "The source cannot replace the insertion point"
    )
    view.draggingExited(info)
    precondition(hint == nil)
    info.draggingLocation = view.convert(NSPoint(x: 220, y: 50), to: nil)
    precondition(view.draggingEntered(info) == .move, "Re-entering empty space restores the last insertion point")
    precondition(view.prepareForDragOperation(info))
    precondition(!info.animatesToDestination, "Disable the system preview animation before accepting the drop")
    precondition(view.performDragOperation(info))
    precondition(dropped == CaptureHistoryInsertion(itemID: otherTargetID, afterTarget: false) && hint == nil)
    precondition(!view.prepareForDragOperation(info), "The completed insertion must not be reused")
    info.draggingLocation = view.convert(NSPoint(x: 20, y: 50), to: nil)
    precondition(view.draggingEntered(info) == .move)
    view.sourceID = nil
    view.sourceID = UUID()
    info.draggingLocation = view.convert(NSPoint(x: 220, y: 50), to: nil)
    precondition(view.draggingEntered(info).isEmpty, "A new drag must not reuse the previous insertion")
    info.draggingSource = nil
    precondition(view.draggingEntered(info).isEmpty)
    precondition(!view.prepareForDragOperation(info), "External files cannot reorder a stale local selection")
  }

  @MainActor
  static func nativeDropBelowLastRow() {
    let view = CaptureHistoryDropView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let info = HistoryTestDraggingInfo()
    defer { info.draggingPasteboard.releaseGlobally() }
    let sourceID = UUID()
    let firstID = UUID()
    let lastID = UUID()
    view.sourceID = sourceID
    view.targets = [
      sourceID: CGRect(x: 20, y: 20, width: 200, height: 100),
      firstID: CGRect(x: 20, y: 150, width: 200, height: 100),
      lastID: CGRect(x: 260, y: 150, width: 200, height: 100)
    ]
    var hint: CaptureHistoryInsertion?
    var dropped: CaptureHistoryInsertion?
    view.updateHint = { hint = $0 }
    view.performDrop = { dropped = $0 }
    for (x, target, after) in [
      (10.0, firstID, false),
      (200.0, firstID, true),
      (250.0, lastID, false),
      (700.0, lastID, true)
    ] {
      info.draggingLocation = view.convert(NSPoint(x: x, y: 500), to: nil)
      precondition(view.draggingUpdated(info) == .move)
      precondition(
        hint == CaptureHistoryInsertion(itemID: target, afterTarget: after),
        "Movement below the grid follows the last row, including gaps and side margins"
      )
    }
    precondition(view.prepareForDragOperation(info))
    precondition(view.performDragOperation(info))
    precondition(dropped == CaptureHistoryInsertion(itemID: lastID, afterTarget: true))

    view.sourceID = lastID
    info.draggingLocation = view.convert(NSPoint(x: 700, y: 500), to: nil)
    precondition(view.draggingEntered(info) == .move)
    precondition(
      hint == CaptureHistoryInsertion(itemID: firstID, afterTarget: true),
      "Below-row targeting excludes the dragged thumbnail"
    )
  }

  static func retentionPreferences() throws {
    var policy = CaptureHistoryRetention()
    policy.limitBytes = 1_000_000_000
    let data = try JSONEncoder().encode(policy)
    let saved = try JSONDecoder().decode([String: Int64].self, from: data)
    precondition(saved["days"] == nil, "Changing storage leaves retention unset")
    let restored = try JSONDecoder().decode(CaptureHistoryRetention.self, from: data)
    precondition(restored.days == 30 && restored.limitBytes == policy.limitBytes)
  }

  static func retentionAndProtection() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let now = Date()
    let id = await repository.begin(kind: .image, devices: [firstDevice, secondDevice], at: now)!
    let first = try await repository.record(capture(device: firstDevice, in: root), in: id)
    _ = try await repository.record(capture(device: secondDevice, in: root), in: id)
    await repository.finish(id, at: now)
    let owner = UUID()
    let beforeExpiry = await repository.cleanupCandidates(now: now.addingTimeInterval(30 * 86400 - 1))
    precondition(beforeExpiry.isEmpty, "The default keeps captures for the full 30 days")
    let future = now.addingTimeInterval(30 * 86400)
    await repository.protect([first.id], owner: owner)
    let protected = await repository.cleanupCandidates(now: future)
    precondition(protected.isEmpty, "One viewed device protects the entire group")
    await repository.delete([id])
    let stillPresent = await repository.currentSnapshot()
    precondition(stillPresent.entries.count == 1, "Manual deletion also respects active viewers")
    await repository.protect([], owner: owner)
    let expired = await repository.cleanupCandidates(now: future)
    precondition(expired.map(\.id) == [id])
    await repository.prune(now: future)
    let empty = await repository.currentSnapshot()
    precondition(empty.entries.isEmpty)

    let older = await repository.begin(kind: .image, devices: [firstDevice, secondDevice], at: now.addingTimeInterval(-600))!
    _ = try await repository.record(capture(device: firstDevice, in: root), in: older)
    _ = try await repository.record(capture(device: secondDevice, in: root), in: older)
    await repository.finish(older, at: now.addingTimeInterval(-600))
    let newer = await repository.begin(kind: .image, devices: [firstDevice], at: now.addingTimeInterval(-300))!
    _ = try await repository.record(capture(device: firstDevice, in: root), in: newer)
    await repository.finish(newer, at: now.addingTimeInterval(-300))
    var policy = CaptureHistoryRetention()
    policy.limitBytes = 250
    let overLimit = await repository.cleanupCandidates(using: policy, now: now)
    precondition(overLimit.map(\.id) == [older], "Prune the whole older group, never one of its files")
  }

  static func oversizedGrace() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let now = Date()
    let id = await repository.begin(kind: .video, devices: [firstDevice], at: now)!
    _ = try await repository.record(capture(device: firstDevice, bytes: 500, in: root), in: id)
    await repository.finish(id, at: now)
    var policy = CaptureHistoryRetention()
    policy.limitBytes = 200
    let duringGrace = await repository.cleanupCandidates(using: policy, now: now.addingTimeInterval(3600))
    precondition(duringGrace.isEmpty)
    let afterGrace = await repository.cleanupCandidates(using: policy, now: now.addingTimeInterval(86401))
    precondition(afterGrace.map(\.id) == [id])
  }

  static func failureAndRecovery() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let id = await repository.begin(kind: .image, devices: [firstDevice, secondDevice])!
    let first = try await repository.record(capture(device: firstDevice, in: root), in: id)
    // Reopening simulates interruption before the second device completes.
    let reopened = CaptureHistoryRepository(root: repository.root)
    let snapshot = await reopened.currentSnapshot()
    precondition(snapshot.entries[0].completedAt != nil)
    precondition(snapshot.entries[0].availableItems.count == 1)
    precondition(snapshot.entries[0].items[1].failure == "Capture was interrupted.")
    try FileManager.default.removeItem(at: first.media.url!)
    let missing = await CaptureHistoryRepository(root: repository.root).currentSnapshot()
    precondition(missing.entries[0].availableItems.isEmpty)
    precondition(missing.entries[0].items[0].failure == "The original file is unavailable.")

    let invalidSource = try capture(device: firstDevice, in: root)
    try FileManager.default.removeItem(at: invalidSource.media.url!)
    let failedID = await reopened.begin(kind: .image, devices: [firstDevice])!
    let result = await reopened.record(invalidSource, in: failedID)
    precondition(result == invalidSource)
    let failed = await reopened.currentSnapshot()
    precondition(failed.errorMessage != nil)
    await reopened.discardEmpty(failedID)
  }
}

@MainActor
private final class HistoryTestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
  var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
  var draggingLocation = NSPoint.zero
  var draggedImageLocation = NSPoint.zero
  var draggedImage: NSImage?
  let draggingPasteboard = NSPasteboard.withUniqueName()
  var draggingSource: Any? = NSObject()
  let draggingSequenceNumber = 1
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = true
  var numberOfValidItemsForDrop = 1
  let springLoadingHighlight: NSSpringLoadingHighlight = .none

  func slideDraggedImage(to screenPoint: NSPoint) {}
  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
    nil
  }

  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [],
    for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}

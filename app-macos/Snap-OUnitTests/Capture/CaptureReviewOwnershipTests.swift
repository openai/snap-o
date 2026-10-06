import AppKit
import Clocks
import DependenciesTestSupport
import Observation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct CaptureReviewOwnershipTests {
  @Test
  func pendingSelectionDoesNotFollowCompletionOrder() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let review = fixture.review(selected: 1)
    let ids = review.items.map(\.id)
    try fixture.batch.items[0].update(.ready(fixture.image(0)))
    #expect(review.selectedItemID == ids[1])
    #expect(review.currentCapture == nil)
    let observed = Task {
      try await waitForState { review.currentCapture != nil }
    }
    try fixture.batch.items[1].update(.ready(fixture.image(1)))
    try await observed.value
    #expect(review.currentCapture?.device.id == "device-1")
    #expect(review.items.map(\.id) == ids)
    await review.close()
  }

  @Test
  func laterResultsPreserveEditsAndSelectedFailure() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let review = fixture.review(selected: 0)
    let first = fixture.batch.items[0]
    try first.update(.ready(fixture.image(0)))
    let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    review.setCrop(crop, for: first.id)
    let second = fixture.batch.items[1]
    review.select(second.id)
    second.update(.failed("Device disconnected"))
    #expect(review.selectedItemID == second.id)
    #expect(review.currentCapture == nil)
    #expect(review.crop(for: first.id) == crop)
    review.select(first.id)
    #expect(try review.exportRequest(for: first.id).crop == crop)
    await review.close()
  }

  @Test
  func closeWaitsForAcceptedSaveBeforeClosingBatch() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let review = fixture.review(selected: 1)
    let save = Task { try await review.saveToHistory(name: "Both devices") }
    try await waitForState { review.isSaving }
    let closed = TestValue(false)
    let close = Task {
      await review.close()
      closed.value = true
    }
    try await waitForState { review.isClosing }
    #expect(!closed.value)
    #expect(fixture.batch.closeCount == 0, "The accepted save still needs the batch")
    try fixture.batch.items[0].update(.ready(fixture.image(0)))
    try fixture.batch.items[1].update(.ready(fixture.image(1)))
    fixture.batch.isComplete = true
    try await save.value
    await close.value
    let saved = await fixture.repository.currentSnapshot()
    let entry = try #require(saved.entries.first)
    #expect(entry.name == "Both devices" && entry.availableItems.count == 2)
    #expect(fixture.batch.closeCount == 1)
    #expect(!review.isSaving)
  }

  @Test
  func saveCanBeFollowedByCloseWithoutWaitingOnItself() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    try fixture.batch.items[0].update(.ready(fixture.image(0)))
    fixture.batch.items[1].update(.failed("Unavailable"))
    fixture.batch.isComplete = true
    let review = fixture.review(selected: 0)
    try await review.saveToHistory(name: "Ready item")
    #expect(!review.isSaving)
    await review.close()
    #expect(fixture.batch.closeCount == 1)
    #expect(await fixture.repository.currentSnapshot().entries.first?.availableItems.count == 1)
  }

  @Test
  func failedSaveKeepsSelectionAndEdits() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.image(0)
    try FileManager.default.removeItem(at: #require(capture.media.url))
    fixture.batch.items[0].update(.ready(capture))
    fixture.batch.isComplete = true
    let review = fixture.review(selected: 0)
    let item = fixture.batch.items[0]
    let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    review.setCrop(crop, for: item.id)
    await #expect(throws: (any Error).self) { try await review.saveToHistory(name: "Missing") }
    #expect(review.errorMessage != nil)
    #expect(!review.isClosing && !review.isSaving)
    #expect(review.selectedItemID == item.id && review.crop(for: item.id) == crop)
    await review.close()
  }

  @Test
  func closeJoinsCancelledDragPreparationAndRepeatedClose() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let image = try fixture.image(0)
    let video = try CaptureMedia(device: image.device, media: .video(url: #require(image.media.url), data: image.media.common))
    fixture.batch.items[0].update(.ready(video))
    let gate = TestSuspension()
    let exporter = CaptureReviewDragExport { _, destination in
      try? await gate.wait()
      try Data([1]).write(to: destination)
      return NSImage(size: CGSize(width: 1, height: 1))
    }
    let review = fixture.review(selected: 0, dragExport: exporter)
    let preparing = Task { await review.prepareDrag(for: fixture.batch.items[0].id) }
    await gate.waitUntilStarted()
    let first = Task { await review.close() }
    try await waitForState { review.isClosing }
    let second = Task { await review.close() }
    #expect(fixture.batch.closeCount == 0, "The reader must finish before its source is released")
    gate.resume()
    await preparing.value
    await first.value
    await second.value
    #expect(fixture.batch.closeCount == 1)
    #expect(!exporter.isPreparing)
    #expect(try !exporter.isReady(for: review.exportRequest(for: fixture.batch.items[0].id)))
  }

  @Test
  func newerDragDoesNotWaitForCancelledPreparation() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let image = try fixture.image(0)
    try fixture.batch.items[0].update(.ready(CaptureMedia(
      device: image.device, media: .video(url: #require(image.media.url), data: image.media.common)
    )))
    let firstGate = TestSuspension()
    let exporter = CaptureReviewDragExport { request, destination in
      if request.trim == nil { try? await firstGate.wait() }
      try Data([1]).write(to: destination)
      return NSImage(size: CGSize(width: 1, height: 1))
    }
    let review = fixture.review(selected: 0, dragExport: exporter)
    let id = fixture.batch.items[0].id
    let first = Task { await review.prepareDrag(for: id) }
    await firstGate.waitUntilStarted()
    review.setTrim(CaptureTrimRange(start: 1, end: 2), for: id)
    let secondRequest = try review.exportRequest(for: id)
    await review.prepareDrag(for: id)
    #expect(exporter.isReady(for: secondRequest), "The cancelled preparation is still blocked")
    firstGate.resume()
    await first.value
    #expect(exporter.isReady(for: secondRequest), "Late cleanup must not replace the newer export")
    await review.close()
  }

  @Test
  func historyDeletionFiltersItemsWithoutCopyingBatchResults() async throws {
    let fixture = Fixture(count: 3)
    defer { fixture.cleanup() }
    let captures = try [fixture.image(0), fixture.image(1)]
    let id = try #require(await fixture.repository.begin(kind: .image, devices: captures.map(\.device)))
    for (item, capture) in zip(fixture.batch.items, captures) {
      await item.update(.ready(fixture.repository.record(capture, in: id)))
    }
    await fixture.repository.finish(id)
    try fixture.batch.items[2].update(.ready(fixture.image(2)))
    fixture.batch.isComplete = true
    fixture.history.start()
    let review = fixture.review(selected: 1)
    review.start()
    try await waitForState { fixture.history.isLoaded }
    let entry = try #require(await fixture.repository.currentSnapshot().entries.first)
    let unselected = try #require(entry.items.first { $0.deviceID == "device-0" })
    await fixture.repository.deleteItem(unselected.id, in: id)
    try await waitForState { review.items.count == 2 }
    #expect(!review.selectedItemWasDeleted)
    #expect(fixture.batch.items.count == 3, "History visibility does not rewrite capture outcomes")
    await fixture.repository.delete([id])
    try await waitForState { review.selectedItemWasDeleted }
    #expect(review.items.map(\.id) == [fixture.batch.items[2].id], "Unsaved results remain visible")
    await review.close()
    await fixture.history.shutdown()
  }

  @Test
  func arrivingMediaStaysVisibleWhileHistoryRefreshes() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let first = try fixture.image(0)
    let entryID = try #require(await fixture.repository.begin(kind: .image, devices: [first.device]))
    await fixture.batch.items[0].update(.ready(fixture.repository.record(first, in: entryID)))
    await fixture.repository.finish(entryID)
    fixture.history.start()
    let review = fixture.review(selected: 1)
    review.start()
    await fixture.repository.delete([entryID])
    try await waitForState { review.items.count == 1 }

    let second = try fixture.image(1)
    let nextID = try #require(await fixture.repository.begin(kind: .image, devices: [second.device]))
    let stored = await fixture.repository.record(second, in: nextID)
    fixture.batch.items[1].update(.ready(stored))
    // The observer has not refreshed since this result arrived.
    #expect(review.currentCapture?.id == stored.id)
    #expect(!review.selectedItemWasDeleted)
    await review.close()
    await fixture.history.shutdown()
  }

  @Test
  func externalHistoryChangesDoNotReassertReviewSelection() async throws {
    let fixture = Fixture(count: 3)
    defer { fixture.cleanup() }
    let captures = try (0 ..< 3).map(fixture.image)
    let entryID = try #require(await fixture.repository.begin(kind: .image, devices: captures.map(\.device)))
    for (item, capture) in zip(fixture.batch.items, captures) {
      await item.update(.ready(fixture.repository.record(capture, in: entryID)))
    }
    await fixture.repository.finish(entryID)
    let entry = try #require(await fixture.repository.currentSnapshot().entries.first)
    let first = try #require(entry.items.first { $0.deviceID == "device-0" })
    let second = try #require(entry.items.first { $0.deviceID == "device-1" })
    let third = try #require(entry.items.first { $0.deviceID == "device-2" })
    try await fixture.repository.recordCapturePaneSelection(#require(second.captureID))
    fixture.history.start()
    let review = fixture.review(selected: 0)
    review.start()
    try await waitForState { fixture.history.entries.first?.capturePaneSelectionID == first.id }

    // Another window changes history while this review keeps its own selection.
    try await fixture.repository.recordCapturePaneSelection(#require(second.captureID))
    await fixture.repository.deleteItem(third.id, in: entryID)
    try await waitForState { review.items.count == 2 }
    #expect(review.selectedItemID == fixture.batch.items[0].id)
    await review.close()
    #expect(await fixture.repository.currentSnapshot().entries.first?.capturePaneSelectionID == second.id)
    await fixture.history.shutdown()
  }

  @Test
  func exportSnapshotsEditsWithoutChangingAnotherItem() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    for index in 0 ..< 2 {
      try fixture.batch.items[index].update(.ready(fixture.image(index)))
    }
    let review = fixture.review(selected: 0)
    let first = fixture.batch.items[0].id
    let second = fixture.batch.items[1].id
    let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    let trim = CaptureTrimRange(start: 1, end: 2)
    review.setCrop(crop, for: first)
    review.setTrim(trim, for: first)
    let request = try review.exportRequest(for: first)
    review.select(second)
    #expect(review.crop(for: second) == CaptureCropGeometry.fullImage)
    #expect(review.trim(for: second) == nil)
    review.setCrop(CaptureCropGeometry.fullImage, for: first)
    review.setTrim(nil, for: first)
    #expect(request.crop == crop && request.trim == trim)
    let staleID = UUID()
    review.select(staleID)
    review.setCrop(crop, for: staleID)
    #expect(review.selectedItemID == second && review.edits[staleID] == nil)
    await review.close()
  }

  @MainActor
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileStore: FileStore
    let repository: CaptureHistoryRepository
    let history: CaptureHistory
    let batch: Batch

    init(count: Int = 2) {
      fileStore = FileStore(baseDir: root.appendingPathComponent("drafts"))
      repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
      history = CaptureHistory(repository: repository)
      batch = Batch(fileStore: fileStore, count: count)
    }

    func review(selected: Int, dragExport: CaptureReviewDragExport = CaptureReviewDragExport()) -> CaptureReviewState {
      CaptureReviewState(
        batch: batch, selectedDeviceID: batch.items[selected].device.id,
        fileStore: fileStore, history: history, dragExport: dragExport
      )
    }

    func image(_ index: Int) throws -> CaptureMedia {
      let item = batch.items[index]
      let date = Date()
      let url = fileStore.makePreviewDestination(deviceID: item.device.id, capturedAt: date, kind: .image)
      let png = try #require(Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1kAAAAASUVORK5CYII="
      ))
      try png.write(to: url)
      return CaptureMedia(
        device: item.device,
        media: .image(url: url, capturedAt: date, display: DisplayInfo(size: CGSize(width: 1, height: 1), densityScale: 1))
      )
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Observable
  @MainActor
  fileprivate final class Batch: CaptureBatch {
    let id = UUID()
    let kind = CaptureKind.screenshots
    let items: [CaptureItem]
    var isComplete = false
    var closeCount = 0
    let fileStore: FileStore

    init(fileStore: FileStore, count: Int) {
      self.fileStore = fileStore
      items = (0 ..< count).map {
        CaptureItem(device: Device(
          id: "device-\($0)", model: "Device \($0)", androidVersion: "16",
          vendorModel: nil, manufacturer: nil, avdName: nil
        ))
      }
    }

    func start() {}
    func close() async {
      closeCount += 1
      fileStore.discardPreviews(items.compactMap(\.media))
    }
  }
}

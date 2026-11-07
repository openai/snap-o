import AppKit
import Clocks
import DependenciesTestSupport
import Observation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct CaptureReviewOwnershipTests {
  @Test
  func pendingCaptureKeepsItsIdentity() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let review = fixture.review()
    let id = review.operation.id
    #expect(review.currentCapture == nil)
    fixture.operation.state = try .ready(fixture.image(0))
    #expect(review.currentCapture?.device.id == "device-0")
    #expect(review.operation.id == id)
    await review.close()
  }

  @Test
  func independentReviewsKeepTheirEditsAndFailures() async throws {
    let first = Fixture()
    let second = Fixture()
    defer { first.cleanup()
      second.cleanup()
    }
    let review = first.review()
    let other = second.review()
    first.operation.state = try .ready(first.image(0))
    let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    review.setCrop(crop)
    second.operation.state = .failed("Device disconnected")
    #expect(other.currentCapture == nil)
    #expect(try review.exportRequest().crop == crop)
    await review.close()
    await other.close()
  }

  @Test
  func closeWaitsForAcceptedSaveBeforeClosingOperation() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let review = fixture.review()
    let save = Task { try await review.saveToHistory(name: "Captured device") }
    try await waitForState { review.isSaving }
    let closed = TestValue(false)
    let close = Task {
      await review.close()
      closed.value = true
    }
    try await waitForState { review.isClosing }
    #expect(!closed.value)
    #expect(fixture.operation.closeCount == 0, "The accepted save still needs the operation")
    fixture.operation.state = try .ready(fixture.image(0))
    fixture.operation.isComplete = true
    try await save.value
    await close.value
    let saved = await fixture.repository.currentSnapshot()
    let entry = try #require(saved.entries.first)
    #expect(entry.name == "Captured device" && entry.availableItems.count == 1)
    #expect(fixture.operation.closeCount == 1)
    #expect(!review.isSaving)
  }

  @Test
  func saveCanBeFollowedByCloseWithoutWaitingOnItself() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    fixture.operation.state = try .ready(fixture.image(0))
    fixture.operation.isComplete = true
    let review = fixture.review()
    try await review.saveToHistory(name: "Ready item")
    #expect(!review.isSaving)
    await review.close()
    #expect(fixture.operation.closeCount == 1)
    #expect(await fixture.repository.currentSnapshot().entries.first?.availableItems.count == 1)
  }

  @Test
  func failedSaveKeepsEdits() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.image(0)
    try FileManager.default.removeItem(at: #require(capture.media.url))
    fixture.operation.state = .ready(capture)
    fixture.operation.isComplete = true
    let review = fixture.review()
    let operation = fixture.operation
    let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    review.setCrop(crop)
    await #expect(throws: (any Error).self) { try await review.saveToHistory(name: "Missing") }
    #expect(review.errorMessage != nil)
    #expect(!review.isClosing && !review.isSaving)
    #expect(review.crop == crop)
    await review.close()
  }

  @Test
  func closeJoinsCancelledDragPreparationAndRepeatedClose() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let image = try fixture.image(0)
    let video = try CaptureMedia(device: image.device, media: .video(url: #require(image.media.url), data: image.media.common))
    fixture.operation.state = .ready(video)
    let gate = TestSuspension()
    let exporter = CaptureReviewDragExport { _, destination in
      try? await gate.wait()
      try Data([1]).write(to: destination)
      return NSImage(size: CGSize(width: 1, height: 1))
    }
    let review = fixture.review(dragExport: exporter)
    let preparing = Task { await review.prepareDrag() }
    await gate.waitUntilStarted()
    let first = Task { await review.close() }
    try await waitForState { review.isClosing }
    let second = Task { await review.close() }
    #expect(fixture.operation.closeCount == 0, "The reader must finish before its source is released")
    gate.resume()
    await preparing.value
    await first.value
    await second.value
    #expect(fixture.operation.closeCount == 1)
    #expect(!exporter.isPreparing)
    #expect(try !exporter.isReady(for: review.exportRequest()))
  }

  @Test
  func newerDragDoesNotWaitForCancelledPreparation() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let image = try fixture.image(0)
    fixture.operation.state = try .ready(CaptureMedia(
      device: image.device, media: .video(url: #require(image.media.url), data: image.media.common)
    ))
    let firstGate = TestSuspension()
    let exporter = CaptureReviewDragExport { request, destination in
      if request.trim == nil { try? await firstGate.wait() }
      try Data([1]).write(to: destination)
      return NSImage(size: CGSize(width: 1, height: 1))
    }
    let review = fixture.review(dragExport: exporter)
    let first = Task { await review.prepareDrag() }
    await firstGate.waitUntilStarted()
    review.setTrim(CaptureTrimRange(start: 1, end: 2))
    let secondRequest = try review.exportRequest()
    await review.prepareDrag()
    #expect(exporter.isReady(for: secondRequest), "The cancelled preparation is still blocked")
    firstGate.resume()
    await first.value
    #expect(exporter.isReady(for: secondRequest), "Late cleanup must not replace the newer export")
    await review.close()
  }

  @Test
  func deletingSavedHistoryLeavesTheDraftAvailable() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    fixture.operation.state = try .ready(fixture.image(0))
    fixture.operation.isComplete = true
    let review = fixture.review()
    let original = review.currentCapture
    try await review.saveToHistory(name: "Saved")
    let entry = try #require(await fixture.repository.currentSnapshot().entries.first)
    await fixture.repository.delete([entry.id])
    #expect(review.currentCapture == original)
    #expect(try FileManager.default.fileExists(atPath: #require(original?.media.url).path))
    await review.close()
  }

  @Test
  func exportSnapshotsEdits() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    fixture.operation.state = try .ready(fixture.image(0))
    let review = fixture.review()
    let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    let trim = CaptureTrimRange(start: 1, end: 2)
    review.setCrop(crop)
    review.setTrim(trim)
    let request = try review.exportRequest()
    review.setCrop(CaptureCropGeometry.fullImage)
    review.setTrim(nil)
    #expect(request.crop == crop && request.trim == trim)
    #expect(review.crop == CaptureCropGeometry.fullImage)
    await review.close()
  }

  @MainActor
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileStore: FileStore
    let repository: CaptureHistoryRepository
    let operation: Operation

    init() {
      fileStore = FileStore(baseDir: root.appendingPathComponent("drafts"))
      repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
      operation = Operation(fileStore: fileStore)
    }

    func review(dragExport: CaptureReviewDragExport = CaptureReviewDragExport()) -> CaptureReviewState {
      CaptureReviewState(
        operation: operation,
        fileStore: fileStore, history: repository, dragExport: dragExport
      )
    }

    func image(_ index: Int) throws -> CaptureMedia {
      let device = Device(
        id: "device-\(index)",
        model: "Device \(index)",
        androidVersion: "16",
        vendorModel: nil,
        manufacturer: nil,
        avdName: nil
      )
      let date = Date()
      let url = fileStore.makePreviewDestination(deviceID: device.id, capturedAt: date, kind: .image)
      let png = try #require(Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1kAAAAASUVORK5CYII="
      ))
      try png.write(to: url)
      return CaptureMedia(
        device: device,
        media: .image(url: url, capturedAt: date, display: DisplayInfo(size: CGSize(width: 1, height: 1), densityScale: 1))
      )
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Observable
  @MainActor
  fileprivate final class Operation: CaptureOperation {
    let id = UUID()
    let kind = CaptureKind.screenshot
    let device: Device
    var state: CaptureState = .pending
    var isComplete = false
    var closeCount = 0
    let fileStore: FileStore

    init(fileStore: FileStore) {
      self.fileStore = fileStore
      device = Device(
        id: "device-0", model: "Device 0", androidVersion: "16",
        vendorModel: nil, manufacturer: nil, avdName: nil
      )
    }

    func start() {}
    func close() async {
      closeCount += 1
      if let media { fileStore.discardPreviews([media]) }
    }
  }
}

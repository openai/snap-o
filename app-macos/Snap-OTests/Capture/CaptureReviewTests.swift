import Foundation
@testable import Snap_O
import Testing

struct CaptureReviewTests {
  @Test
  func insetFitsAndCentersBelowToolbar() {
    for size in [CGSize(width: 400, height: 800), CGSize(width: 800, height: 400), CGSize(width: 260, height: 500)] {
      for ratio: CGFloat in [0.5, 1, 2] {
        let frame = CaptureReviewLayout.mediaFrame(in: size, aspectRatio: ratio)
        let top = CaptureReviewLayout.toolbarSpacing * 2 + CaptureReviewLayout.toolbarHeight
        #expect(abs(frame.width / frame.height - ratio) < 0.0001)
        #expect(frame.minX >= 16 && frame.maxX <= size.width - 16)
        #expect(frame.minY >= top && frame.maxY <= size.height - 16)
        #expect(abs(frame.midX - size.width / 2) < 0.0001)
        #expect(abs(frame.midY - (top + size.height - 16) / 2) < 0.0001)
        #expect(abs(frame.width - (size.width - 32)) < 0.0001 || abs(frame.height - (size.height - top - 16)) < 0.0001)
      }
    }
  }

  @Test
  func savingPublishesNamedBatchAndPreservesSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(baseDir: root.appendingPathComponent("drafts"))
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let captures = try [makeCapture("one", store: store), makeCapture("two", store: store)]
    #expect(await repository.currentSnapshot().entries.isEmpty)

    try await repository.saveReviewedCaptures(captures, name: "  A capture  ", selectedID: captures[1].id)
    let entry = try #require(await repository.currentSnapshot().entries.first)
    #expect(entry.name == "A capture")
    #expect(entry.items.count == 2)
    #expect(entry.frontItem?.captureID == captures[1].id)
    #expect(entry.capturedAt == captures[0].media.capturedAt)
    #expect(entry.completedAt != nil)

    try store.discardPreviews(captures)
    let reloaded = await CaptureHistoryRepository(root: repository.root).currentSnapshot()
    #expect(reloaded.entries == [entry])
    for item in entry.items {
      #expect(try Data(contentsOf: entry.fileURL(for: item, in: repository.root)) == Data([1, 2, 3]))
    }
  }

  @Test
  func failedBatchSavePublishesNothingAndCanBeRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(baseDir: root.appendingPathComponent("drafts"))
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let captures = try [makeCapture("one", store: store), makeCapture("two", store: store)]
    let missing = try #require(captures[1].media.url)
    try FileManager.default.removeItem(at: missing)
    await #expect(throws: (any Error).self) {
      try await repository.saveReviewedCaptures(captures, name: "", selectedID: nil)
    }
    #expect(await repository.currentSnapshot().entries.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: repository.root.path).isEmpty)
    #expect(try FileManager.default.fileExists(atPath: #require(captures[0].media.url).path))

    try Data([1, 2, 3]).write(to: missing)
    try await repository.saveReviewedCaptures(captures, name: "", selectedID: nil)
    let snapshot = await repository.currentSnapshot()
    #expect(snapshot.entries.count == 1)
    #expect(snapshot.entries.first?.name == nil)
  }

  @Test
  func recordingsAreSavedAsVideos() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(baseDir: root.appendingPathComponent("drafts"))
    let repository = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    let capture = try makeCapture("one", store: store, video: true)
    try await repository.saveReviewedCaptures([capture], name: "Recording", selectedID: capture.id)
    let entry = try #require(await repository.currentSnapshot().entries.first)
    #expect(entry.kind == .video)
    #expect(entry.items.first?.captureID == capture.id)
  }

  @Test
  func discardRemovesOnlyTemporaryCaptures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(baseDir: root.appendingPathComponent("drafts"))
    let capture = try makeCapture("one", store: store)
    let otherStore = FileStore(baseDir: root.appendingPathComponent("other"))
    let external = try makeCapture("two", store: otherStore)
    try store.discardPreviews([capture, external])
    #expect(try !FileManager.default.fileExists(atPath: #require(capture.media.url).path))
    #expect(try FileManager.default.fileExists(atPath: #require(external.media.url).path))
    try store.discardPreviews([capture])
  }

  private func makeCapture(_ id: String, store: FileStore, video: Bool = false) throws -> CaptureMedia {
    let date = Date()
    let url = store.makePreviewDestination(deviceID: id, capturedAt: date, kind: video ? .video : .image)
    try Data([1, 2, 3]).write(to: url)
    let display = DisplayInfo(size: CGSize(width: 100, height: 200), densityScale: 2)
    let media: Media = video
      ? .video(url: url, capturedAt: date, display: display)
      : .image(url: url, capturedAt: date, display: display)
    return CaptureMedia(
      device: Device(id: id, model: id, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: media
    )
  }
}

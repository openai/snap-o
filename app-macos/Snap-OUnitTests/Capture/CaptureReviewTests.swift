import Foundation
import Testing

struct CaptureReviewTests {
  @Test(arguments: [CGFloat(0.5), 1, 2])
  func insetPreservesAspectRatio(ratio: CGFloat) {
    let frame = CaptureReviewLayout.mediaFrame(in: CGSize(width: 400, height: 800), aspectRatio: ratio)
    #expect(abs(frame.width / frame.height - ratio) < 0.0001)
  }

  @Test(arguments: [CGSize(width: 400, height: 800), CGSize(width: 800, height: 400)])
  func insetStaysBelowToolbarAndInsideMargins(size: CGSize) {
    let frame = CaptureReviewLayout.mediaFrame(in: size, aspectRatio: 0.5)
    let top = CaptureReviewLayout.toolbarSpacing * 2 + CaptureReviewLayout.toolbarHeight
    let available = CGRect(x: 16, y: top, width: size.width - 32, height: size.height - top - 16)
    #expect(available.contains(frame))
  }

  @Test
  func savingTrimsCaptureName() async throws {
    try await withRepository { repository, captures in
      try await repository.saveReviewedCaptures(captures, name: "  A capture  ", selectedID: nil)
      #expect(await repository.currentSnapshot().entries.first?.name == "A capture")
    }
  }

  @Test
  func savingPreservesSelectedCapture() async throws {
    try await withRepository { repository, captures in
      try await repository.saveReviewedCaptures(captures, name: "", selectedID: captures[1].id)
      #expect(await repository.currentSnapshot().entries.first?.frontItem?.captureID == captures[1].id)
    }
  }

  @Test
  func savedFilesSurviveRemovingPreviews() async throws {
    try await withRepository { repository, captures in
      try await repository.saveReviewedCaptures(captures, name: "", selectedID: nil)
      for capture in captures {
        try FileManager.default.removeItem(at: #require(capture.media.url))
      }
      let entry = try #require(await repository.currentSnapshot().entries.first)
      for item in entry.items {
        #expect(try Data(contentsOf: entry.fileURL(for: item, in: repository.root)) == Data([1, 2, 3]))
      }
    }
  }

  @Test
  func failedBatchPublishesNoPartialEntry() async throws {
    try await withRepository { repository, captures in
      try FileManager.default.removeItem(at: #require(captures[1].media.url))
      await #expect(throws: (any Error).self) {
        try await repository.saveReviewedCaptures(captures, name: "", selectedID: nil)
      }
      #expect(await repository.currentSnapshot().entries.isEmpty)
    }
  }

  @Test
  func loadingRemovesAbandonedSave() async throws {
    try await withRepository { repository, _ in
      let staging = repository.root.appendingPathComponent(".\(UUID().uuidString).partial")
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      try Data([1, 2, 3]).write(to: staging.appendingPathComponent("capture.mp4"))
      _ = await repository.currentSnapshot()
      #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
  }

  @Test
  func loadingPreservesUnrelatedHiddenDirectory() async throws {
    try await withRepository { repository, _ in
      let directory = repository.root.appendingPathComponent(".other.partial")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      _ = await repository.currentSnapshot()
      #expect(FileManager.default.fileExists(atPath: directory.path))
    }
  }

  @Test
  func discardPreservesExternalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(baseDir: root.appendingPathComponent("drafts"))
    let capture = try makeCapture("one", directory: root.appendingPathComponent("drafts"))
    let external = try makeCapture("two", directory: root.appendingPathComponent("other"))
    store.discardPreviews([capture, external])
    #expect(try FileManager.default.fileExists(atPath: #require(external.media.url).path))
  }

  @Test
  func discardContinuesAfterFileRemovalFails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileStore(baseDir: root)
    let locked = try makeCapture("locked", directory: root)
    let removable = try makeCapture("removable", directory: root)
    let lockedURL = try #require(locked.media.url)
    let removableURL = try #require(removable.media.url)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedURL.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedURL.path) }
    #expect(throws: (any Error).self) {
      try FileManager.default.removeItem(at: lockedURL)
    }

    store.discardPreviews([locked, removable])

    #expect(FileManager.default.fileExists(atPath: lockedURL.path))
    #expect(!FileManager.default.fileExists(atPath: removableURL.path))
  }

  private func withRepository(
    _ test: (CaptureHistoryRepository, [CaptureMedia]) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let captures = try [
      makeCapture("one", directory: root.appendingPathComponent("drafts")),
      makeCapture("two", directory: root.appendingPathComponent("drafts"))
    ]
    try await test(CaptureHistoryRepository(root: root.appendingPathComponent("history")), captures)
  }

  private func makeCapture(_ id: String, directory: URL) throws -> CaptureMedia {
    let date = Date()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(id).png")
    try Data([1, 2, 3]).write(to: url)
    let display = DisplayInfo(size: CGSize(width: 100, height: 200), densityScale: 2)
    let media = Media.image(url: url, capturedAt: date, display: display)
    return CaptureMedia(
      device: Device(id: id, model: id, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: media
    )
  }
}

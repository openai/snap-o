import AppKit
@testable import Snap_O
import Testing

@MainActor
struct CaptureReviewDragExportTests {
  private struct Pending {
    let destination: URL
    let completion: CheckedContinuation<NSImage, Error>

    func finish() throws {
      try Data([1, 2, 3]).write(to: destination)
      completion.resume(returning: NSImage(size: CGSize(width: 64, height: 32)))
    }
  }

  @Test
  func oldExportCannotReplaceNewCrop() async throws {
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    let pending = TestValue<[Pending]>([])
    let exporter = CaptureReviewDragExport { _, _, _, destination in
      try await withCheckedThrowingContinuation { completion in
        pending.value.append(Pending(destination: destination, completion: completion))
      }
    }
    let first = request(crop: CaptureCropGeometry.fullImage)
    let second = CaptureReviewDragExport.Request(
      capture: first.capture, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    )
    let oldTask = Task { await exporter.prepare(first, fileStore: store) }
    try await waitForState { pending.value.count == 1 }
    #expect(!exporter.isReady(for: first))
    let newTask = Task { await exporter.prepare(second, fileStore: store) }
    try await waitForState { pending.value.count == 2 }
    #expect(!exporter.isReady(for: first))
    #expect(!exporter.isReady(for: second))

    try pending.value[1].finish()
    await newTask.value
    #expect(exporter.isReady(for: second))
    try pending.value[0].finish()
    await oldTask.value
    #expect(exporter.isReady(for: second))
    #expect(!exporter.isReady(for: first))
    #expect(!FileManager.default.fileExists(atPath: pending.value[0].destination.path))
    let item = try #require(exporter.draggingItem(for: second, frame: CGRect(x: 0, y: 0, width: 64, height: 32)))
    #expect(item.item as? URL == pending.value[1].destination)
  }

  @Test
  func cancelledExportCannotPublishOrLeaveAPartialFile() async throws {
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    let pending = TestValue<[Pending]>([])
    let exporter = CaptureReviewDragExport { _, _, _, destination in
      try await withCheckedThrowingContinuation { completion in
        pending.value.append(Pending(destination: destination, completion: completion))
      }
    }
    let request = request(crop: CaptureCropGeometry.fullImage)
    let task = Task { await exporter.prepare(request, fileStore: store) }
    try await waitForState { pending.value.count == 1 }
    task.cancel()
    try pending.value[0].finish()
    await task.value
    #expect(!exporter.isReady(for: request))
    #expect(!exporter.isPreparing)
    #expect(exporter.errorMessage == nil)
    #expect(!FileManager.default.fileExists(atPath: pending.value[0].destination.path))
  }

  @Test
  func failedExportCannotBeDragged() async throws {
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    var partialFile: URL?
    let exporter = CaptureReviewDragExport { _, _, _, destination in
      partialFile = destination
      try Data([1]).write(to: destination)
      throw CocoaError(.fileReadCorruptFile)
    }
    let request = request(crop: CaptureCropGeometry.fullImage)
    await exporter.prepare(request, fileStore: store)
    #expect(exporter.draggingItem(for: request, frame: CGRect(x: 0, y: 0, width: 64, height: 32)) == nil)
    #expect(!exporter.isPreparing)
    #expect(exporter.errorMessage != nil)
    #expect(try !FileManager.default.fileExists(atPath: #require(partialFile).path))
  }

  @Test(arguments: [false, true])
  func stoppingRemovesOnlyUnusedExports(dragged: Bool) async throws {
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    var exported: URL?
    let exporter = CaptureReviewDragExport { _, _, _, destination in
      exported = destination
      try Data([1, 2, 3]).write(to: destination)
      return NSImage(size: CGSize(width: 64, height: 32))
    }
    let request = request(crop: CaptureCropGeometry.fullImage)
    await exporter.prepare(request, fileStore: store)
    if dragged {
      _ = try #require(exporter.draggingItem(for: request, frame: CGRect(x: 0, y: 0, width: 64, height: 32)))
    }
    exporter.stop()
    #expect(!exporter.isReady(for: request))
    #expect(try FileManager.default.fileExists(atPath: #require(exported).path) == dragged)
  }

  private func request(crop: CGRect) -> CaptureReviewDragExport.Request {
    let capture = CaptureMedia(
      device: Device(id: "test", model: "Test", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: .video(
        url: URL(fileURLWithPath: "/synthetic-source.mp4"), capturedAt: Date(),
        display: DisplayInfo(size: CGSize(width: 64, height: 32), densityScale: 2)
      )
    )
    return .init(capture: capture, crop: crop)
  }
}

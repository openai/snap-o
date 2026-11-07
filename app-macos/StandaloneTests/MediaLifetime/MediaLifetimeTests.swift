import AppKit
import Clocks
import CoreVideo
import Darwin
import Dependencies
import DependenciesTestSupport
import ImageIO
import Testing
import UniformTypeIdentifiers

@main
struct MediaLifetimeTestRunner {
  static func main() async {
    await exit(Testing.__swiftPMEntryPoint())
  }
}

@MainActor
@Suite(.dependency(\.continuousClock, ImmediateClock()))
struct MediaLifetimeTests {
  @Test(arguments: [false, true])
  func discardKeepsActiveSources(forceCopy: Bool) async throws {
    let fixture = Fixture(forceCopy: forceCopy)
    defer { fixture.cleanup() }
    let capture = try fixture.capture(video: forceCopy)
    let request = CaptureExportRequest(
      capture: capture,
      crop: CGRect(x: 0, y: 0, width: 0.5, height: 1),
      trim: CaptureTrimRange(start: 1, end: 2)
    )
    let gate = TestGate()
    let retained = TestValue<CaptureExportRequest?>(nil)
    let task = Task {
      try await fixture.store.withRetainedSource(request) { copy in
        retained.value = copy
        await gate.wait()
        #expect(copy.capture.id == request.capture.id)
        #expect(copy.capture.device == request.capture.device)
        #expect(copy.capture.media.common == request.capture.media.common)
        #expect(copy.edits == request.edits)
        let data = try Data(contentsOf: #require(copy.capture.media.url))
        #expect(data == fixture.bytes)
      }
    }
    try await waitForState { retained.value != nil }
    fixture.store.discardPreviews([capture])
    #expect(!fixture.exists(capture))
    await gate.open()
    try await task.value
    #expect(fixture.files.isEmpty)
  }

  @Test
  func historyDeletionDoesNotInterruptAnExport() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    try await fixture.history.saveReviewedCaptures([capture], name: "Saved", selectedID: capture.id)
    let snapshot = await fixture.history.currentSnapshot()
    let entry = try #require(snapshot.entries.first)
    let item = try #require(entry.items.first)
    let source = entry.fileURL(for: item, in: fixture.history.root)
    let request = CaptureExportRequest(capture: capture).replacingSource(with: source)
    let gate = TestGate()
    let retained = TestValue<URL?>(nil)
    let task = Task {
      try await fixture.store.withRetainedSource(request) { copies in
        retained.value = copies.capture.media.url
        await gate.wait()
        let data = try Data(contentsOf: #require(retained.value))
        #expect(data == fixture.bytes)
      }
    }
    try await waitForState { retained.value != nil }
    await fixture.history.delete([entry.id])
    #expect(!FileManager.default.fileExists(atPath: source.path))
    await gate.open()
    try await task.value
    #expect(try !FileManager.default.fileExists(atPath: #require(retained.value).path))
  }

  @Test
  func retentionFailureRemovesEarlierLinksWithoutStartingWork() throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let missing = fixture.root.appendingPathComponent("missing")
    var started = false
    do {
      try fixture.store.withRetainedFiles([#require(capture.media.url), missing]) { _ in
        started = true
      }
      Issue.record("Missing source should fail retention")
    } catch {}
    #expect(!started)
    let remainingPaths = fixture.files.map(\.standardizedFileURL.path)
    let originalPath = try #require(capture.media.url).standardizedFileURL.path
    #expect(remainingPaths == [originalPath])
  }

  @Test
  func symlinkSourceRetainsTheFileItPointsTo() throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let source = try #require(capture.media.url)
    let symlink = fixture.root.appendingPathComponent("source-link.png")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    try fixture.store.withRetainedFiles([symlink]) { retained in
      try FileManager.default.removeItem(at: source)
      try FileManager.default.removeItem(at: symlink)
      #expect(try Data(contentsOf: retained[0]) == fixture.bytes)
    }
    #expect(fixture.files.isEmpty)
  }

  @Test
  func failedOperationReleasesRetainedSources() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    do {
      try await fixture.store.withRetainedSource(CaptureExportRequest(capture: capture)) { _ in
        fixture.store.discardPreviews([capture])
        throw CocoaError(.fileWriteUnknown)
      }
      Issue.record("Operation should fail")
    } catch {}
    #expect(fixture.files.isEmpty)
  }

  @Test
  func cancelledDragKeepsItsSourceUntilPreparationFinishes() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture(video: true)
    let request = CaptureExportRequest(capture: capture)
    let gate = TestGate()
    let source = TestValue<URL?>(nil)
    let destination = TestValue<URL?>(nil)
    let exporter = CaptureReviewDragExport { retained, output in
      source.value = retained.capture.media.url
      destination.value = output
      await gate.wait()
      try Data(contentsOf: #require(source.value)).write(to: output)
      return NSImage(size: CGSize(width: 8, height: 8))
    }
    let task = Task { await exporter.prepare(request, fileStore: fixture.store) }
    try await waitForState { source.value != nil }
    fixture.store.discardPreviews([capture])
    task.cancel()
    exporter.stop()
    #expect(try FileManager.default.fileExists(atPath: #require(source.value).path))
    await gate.open()
    await task.value
    #expect(!exporter.isReady(for: request))
    #expect(exporter.errorMessage == nil)
    #expect(fixture.files.isEmpty)
  }

  @Test
  func dragRetainsSourceBeforeDebouncing() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let fixture = Fixture()
      defer { fixture.cleanup() }
      let capture = try fixture.capture(video: true)
      let request = CaptureExportRequest(capture: capture, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
      let exporter = CaptureReviewDragExport { retained, output in
        try Data(contentsOf: #require(retained.capture.media.url)).write(to: output)
        return NSImage(size: CGSize(width: 8, height: 8))
      }
      let task = Task { await exporter.prepare(request, fileStore: fixture.store) }
      try await waitForState { exporter.isPreparing }
      fixture.store.discardPreviews([capture])
      await clock.advance(by: .milliseconds(200))
      await task.value
      #expect(exporter.isReady(for: request))
      exporter.stop()
      #expect(fixture.files.isEmpty)
      try await clock.checkSuspension()
    }
  }

  @Test
  func historyCommitSurvivesDraftDiscardAndReopening() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    try await fixture.store.saveReview(CaptureExportRequest(capture: capture), name: "Saved", history: fixture.history)
    #expect(fixture.files.count == 1)
    fixture.store.discardPreviews([capture])
    #expect(fixture.files.isEmpty)
    let reopened = CaptureHistoryRepository(root: fixture.history.root)
    let snapshot = await reopened.currentSnapshot()
    let entry = try #require(snapshot.entries.first)
    #expect(snapshot.entries.count == 1 && entry.name == "Saved")
    #expect(entry.items.compactMap(\.captureID) == [capture.id])
    let item = try #require(entry.frontItem)
    #expect(try Data(contentsOf: entry.fileURL(for: item, in: reopened.root)) == fixture.bytes)
  }

  @Test(arguments: [false, true])
  func failedSavePreservesDraftsAndRemovesAllIntermediates(failCommit: Bool) async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let invalid = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    let request = CaptureExportRequest(capture: capture, crop: failCommit ? CaptureCropGeometry.fullImage : invalid)
    if failCommit { try fixture.bytes.write(to: fixture.history.root) }
    do {
      try await fixture.store.saveReview(request, name: "Saved", history: fixture.history)
      Issue.record("Export or commit should fail")
    } catch {}
    #expect(fixture.exists(capture))
    #expect(fixture.files.count == 1)
    #expect(await fixture.history.currentSnapshot().entries.isEmpty)
  }

  @Test
  func croppedImageExportsHaveTheirOwnLifetime() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let source = try #require(capture.media.url)
    let context = try #require(CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    #expect(CGImageDestinationFinalize(writer))
    let request = CaptureExportRequest(capture: capture, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
    let drag = try fixture.store.makeImageDrag(request)
    let save = fixture.root.appendingPathComponent("saved.png")
    try fixture.store.saveImage(at: source, crop: request.crop, to: save)
    try await fixture.store.saveReview(request, name: "Cropped", history: fixture.history)
    fixture.store.discardPreviews([capture])
    let snapshot = await fixture.history.currentSnapshot()
    #expect(snapshot.entries.count == 1)
    let entry = try #require(snapshot.entries.first)
    let item = try #require(entry.availableItems.first)
    let savedReview = entry.fileURL(for: item, in: fixture.history.root)
    for url in [drag, save, savedReview] {
      let exported = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
      let pixels = try #require(CGImageSourceCreateImageAtIndex(exported, 0, nil))
      #expect(pixels.width == 4 && pixels.height == 8)
    }
  }

  @Test
  func dragAndSavedCopiesRemainIndependentOfTheDraft() throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture(video: true)
    let source = try #require(capture.media.url)
    let drag = try fixture.store.makeDragCopy(of: source, capturedAt: capture.media.capturedAt, kind: .video)
    let saved = fixture.root.appendingPathComponent("saved.mp4")
    try fixture.store.saveFile(at: source, to: saved)
    try Data([9]).write(to: drag)
    #expect(try Data(contentsOf: source) == fixture.bytes)
    fixture.store.discardPreviews([capture])
    fixture.store.discardTemporaryFile(at: saved)
    #expect(try Data(contentsOf: saved) == fixture.bytes)
    #expect(try Data(contentsOf: drag) == Data([9]))
  }

  @Test
  func failedImageDragLeavesOnlyTheDraft() throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    #expect(throws: (any Error).self) { try fixture.store.makeImageDrag(CaptureExportRequest(capture: capture)) }
    let remainingPaths = fixture.files.map(\.standardizedFileURL.path)
    let originalPath = try #require(capture.media.url).standardizedFileURL.path
    #expect(remainingPaths == [originalPath])
  }

  @Test
  func fileShutdownJoinsExportsAndRejectsNewWork() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let request = CaptureExportRequest(capture: capture)
    let gate = TestGate()
    let export = Task {
      try await fixture.store.withRetainedSource(request) { retained in
        await gate.wait()
        let bytes = try Data(contentsOf: #require(retained.capture.media.url))
        #expect(bytes == fixture.bytes)
      }
    }
    await waitForActorTestState { await gate.waitCount == 1 }
    let otherGate = TestGate()
    let otherExport = Task {
      try await fixture.store.withExport { await otherGate.wait() }
    }
    await waitForActorTestState { await otherGate.waitCount == 1 }
    let firstFinished = TestValue(false)
    let first = await startTestTask {
      await fixture.store.shutdown()
      firstFinished.value = true
    }
    let secondFinished = TestValue(false)
    let second = await startTestTask {
      await fixture.store.shutdown()
      secondFinished.value = true
    }
    #expect(!firstFinished.value && !secondFinished.value)
    #expect(throws: CancellationError.self) {
      try fixture.store.withExport { Issue.record("New frame export should be rejected") }
    }
    do {
      try await fixture.store.withRetainedSource(request) { _ in
        Issue.record("New file export should be rejected")
      }
      Issue.record("Expected closed export admission")
    } catch is CancellationError {} catch { Issue.record(error) }
    fixture.store.discardPreviews([capture])
    await gate.open()
    try await export.value
    #expect(!firstFinished.value && !secondFinished.value, "Shutdown waits for every export")
    await otherGate.open()
    try await otherExport.value
    await first.value
    await second.value
    #expect(fixture.files.isEmpty)
  }

  @Test
  func frameExporterRejectsWorkAfterShutdownStarts() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    let exporter = LivePreviewFrameExporter()
    let device = Device(
      id: "test", model: "Test", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil
    )
    fixture.store.beginShutdown()
    #expect(throws: CancellationError.self) { try exporter.export(pixels, device: device, to: fixture.store) }
    await fixture.store.shutdown()
    #expect(fixture.files.isEmpty)
  }

  @Test
  func failedRetentionReleasesExportBeforeShutdown() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("missing.png")
    #expect(throws: (any Error).self) {
      try fixture.store.withRetainedFiles([source]) { _ in
        Issue.record("Missing source cannot start an export")
      }
    }
    await fixture.store.shutdown()
    #expect(fixture.files.isEmpty)
  }

  @Test
  func historyShutdownJoinsAcceptedFramesAndRejectsNewOnes() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let source = try #require(capture.media.url)
    let writer = TestGate()
    let history = CaptureHistory(repository: fixture.history, writeFrame: { frame in
      await writer.wait()
      await fixture.history.recordFrame(frame)
    })
    history.recordFrame(capture)
    await waitForActorTestState { await writer.waitCount == 1 }
    let firstFinished = TestValue(false)
    let first = await startTestTask {
      await history.shutdown()
      firstFinished.value = true
    }
    let secondFinished = TestValue(false)
    let second = await startTestTask {
      await history.shutdown()
      secondFinished.value = true
    }
    history.recordFrame(capture)
    #expect(!firstFinished.value && !secondFinished.value)
    await writer.open()
    await first.value
    await second.value
    let snapshot = await fixture.history.currentSnapshot()
    #expect(snapshot.entries.count == 1)
    let entry = try #require(snapshot.entries.first)
    #expect(entry.completedAt != nil && entry.availableItems.count == 1)
    let item = try #require(entry.availableItems.first)
    #expect(try Data(contentsOf: entry.fileURL(for: item, in: fixture.history.root)) == fixture.bytes)
    #expect(try Data(contentsOf: source) == fixture.bytes)
    #expect(await writer.waitCount == 1, "Shutdown must reject new frames")
  }

  @Test
  func historyShutdownJoinsAcceptedUpdatesInOrder() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    try await fixture.history.recordFrame(fixture.capture())
    let initial = await fixture.history.currentSnapshot()
    let entry = try #require(initial.entries.first)
    let history = CaptureHistory(repository: fixture.history)
    let gate = TestGate()
    history.update { repository in
      await gate.wait()
      await repository.rename(entry.id, to: "First")
    }
    let last = try #require(history.update { await $0.rename(entry.id, to: "Last") })
    last.cancel()
    await waitForActorTestState { await gate.waitCount == 1 }
    let firstFinished = TestValue(false)
    let first = await startTestTask {
      await history.shutdown()
      firstFinished.value = true
    }
    let repeatedFinished = TestValue(false)
    let repeated = await startTestTask {
      await history.shutdown()
      repeatedFinished.value = true
    }
    #expect(history.update { await $0.rename(entry.id, to: "Rejected") } == nil)
    #expect(!firstFinished.value && !repeatedFinished.value)
    let pending = await fixture.history.currentSnapshot()
    #expect(pending.entries.first?.name == nil, "A later update must not overtake the blocked update")
    await gate.open()
    await first.value
    await repeated.value
    let reopened = CaptureHistoryRepository(root: fixture.history.root)
    let saved = await reopened.currentSnapshot()
    #expect(saved.entries.first?.name == "Last", "Accepted writes survive caller cancellation and persist in order")
  }

  @Test
  func historyUpdatesWaitForAcceptedFrameImports() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let capture = try fixture.capture()
    let gate = TestGate()
    let history = CaptureHistory(repository: fixture.history) { frame in
      await gate.wait()
      await fixture.history.recordFrame(frame)
    }
    history.recordFrame(capture)
    let deletion = try #require(history.update { repository in
      let snapshot = await repository.currentSnapshot()
      await repository.delete(Set(snapshot.entries.map(\.id)))
    })
    await waitForActorTestState { await gate.waitCount == 1 }
    await gate.open()
    await deletion.value
    await history.shutdown()
    let reopened = CaptureHistoryRepository(root: fixture.history.root)
    let saved = await reopened.currentSnapshot()
    #expect(saved.entries.isEmpty, "The deletion must run after the accepted frame has been imported")
  }

  @Test
  func frameHistoryKeepsItsDeviceSnapshotAndCaptureTime() async throws {
    let fixture = Fixture()
    defer { fixture.cleanup() }
    let writer = TestGate()
    let history = CaptureHistory(repository: fixture.history, writeFrame: { frame in
      await writer.wait()
      await fixture.history.recordFrame(frame)
    })
    let recorded = TestValue<CaptureMedia?>(nil)
    let store = FileStore(baseDir: fixture.root.appendingPathComponent("frames"), frameExportHandler: {
      recorded.value = $0
      history.recordFrame($0)
    })
    let original = Device(
      id: "same-serial", model: "Original", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil,
      connection: DeviceTarget(serial: "same-serial", transportID: "1")
    )
    var currentDevice = original
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 16, 24, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    let frame = try LivePreviewFrameExporter().export(pixels, device: currentDevice, to: store)
    await waitForActorTestState { await writer.waitCount == 1 }
    original.connection?.invalidate()
    currentDevice = Device(
      id: original.id, model: "Replacement", androidVersion: "17", vendorModel: nil, manufacturer: nil, avdName: nil,
      connection: DeviceTarget(serial: original.id, transportID: "1")
    )
    #expect(currentDevice.connection != original.connection)
    await writer.open()
    await history.shutdown()
    let capture = try #require(recorded.value)
    #expect(capture.device == original)
    #expect(capture.media.url == frame.url)
    let snapshot = await fixture.history.currentSnapshot()
    let entry = try #require(snapshot.entries.first)
    let item = try #require(entry.availableItems.first)
    #expect(snapshot.entries.count == 1 && entry.items.count == 1)
    #expect(entry.capturedAt == capture.media.capturedAt)
    #expect(item.deviceID == original.id && item.deviceName == original.displayTitle)
    #expect(item.width == 16 && item.height == 24)
    #expect(FileManager.default.fileExists(atPath: frame.url.path), "History must leave the drag source intact")
  }

  @Test
  func historyShutdownReleasesItsBackgroundClock() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let fixture = Fixture()
      defer { fixture.cleanup() }
      let history = CaptureHistory(repository: fixture.history)
      history.start()
      await waitForObservedTestState { history.isLoaded }
      await history.shutdown()
      await history.shutdown()
      try await clock.checkSuspension()
    }
  }

  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bytes = Data([1, 2, 3, 4])
    let store: FileStore
    let history: CaptureHistoryRepository

    init(forceCopy: Bool = false) {
      store = FileStore(baseDir: root.appendingPathComponent("drafts"), linkFile: { source, destination in
        if forceCopy { throw CocoaError(.featureUnsupported) }
        try FileManager.default.linkItem(at: source, to: destination)
      })
      history = CaptureHistoryRepository(root: root.appendingPathComponent("history"))
    }

    func capture(video: Bool = false) throws -> CaptureMedia {
      let date = Date()
      let url = store.makePreviewDestination(deviceID: "test", capturedAt: date, kind: video ? .video : .image)
      try bytes.write(to: url)
      let common = MediaCommon(capturedAt: date, display: DisplayInfo(size: CGSize(width: 8, height: 8), densityScale: 2))
      return CaptureMedia(
        device: Device(id: "test", model: "Test", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
        media: video ? .video(url: url, data: common) : .image(url: url, data: common)
      )
    }

    func exists(_ capture: CaptureMedia) -> Bool {
      capture.media.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    var files: [URL] {
      let directory = root.appendingPathComponent("drafts")
      let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
      return (enumerator?.allObjects as? [URL] ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}

import AppKit
import Foundation
import Observation

/// Owns edits, readers, and accepted exports for one capture.
@Observable
@MainActor
final class CaptureReviewState {
  let operation: any CaptureOperation
  let fileStore: FileStore
  let playback: CaptureReviewPlayback
  let dragExport: CaptureReviewDragExport
  private(set) var edits = MediaEdits()
  private(set) var isClosing = false
  private(set) var isSaving = false
  private(set) var errorMessage: String?
  private(set) var imageCopyID: UUID?

  private let history: CaptureHistoryRepository
  private enum Reader { case playback, drag }
  private struct Read {
    let kind: Reader
    let task: Task<Void, Never>
  }

  @ObservationIgnored private var readers: [UUID: Read] = [:]
  @ObservationIgnored private var exports: [UUID: Task<Void, Error>] = [:]
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(
    operation: any CaptureOperation, fileStore: FileStore,
    history: CaptureHistoryRepository, dragExport: CaptureReviewDragExport = CaptureReviewDragExport(),
    playback: CaptureReviewPlayback = CaptureReviewPlayback()
  ) {
    self.operation = operation
    self.fileStore = fileStore
    self.history = history
    self.dragExport = dragExport
    self.playback = playback
  }

  var allowsReplacement: Bool {
    !isSaving
  }

  var currentCapture: CaptureMedia? {
    operation.media
  }

  var crop: CGRect {
    edits.crop
  }

  var trim: CaptureTrimRange? {
    edits.trim
  }

  func setVisible(_ visible: Bool) {
    guard !isClosing else { return }
    playback.setPaneVisible(visible)
  }

  func setCrop(_ crop: CGRect) {
    guard !isClosing, !isSaving, currentCapture != nil else { return }
    edits.crop = crop
  }

  func setTrim(_ range: CaptureTrimRange?) {
    guard !isClosing, !isSaving, currentCapture != nil else { return }
    edits.trim = range
  }

  func exportRequest() throws -> CaptureExportRequest {
    guard let capture = currentCapture else { throw CocoaError(.fileReadNoSuchFile) }
    return CaptureExportRequest(capture: capture, edits: edits)
  }

  func clearError() {
    errorMessage = nil
  }

  func copyImage(to pasteboard: NSPasteboard = .general) throws {
    guard !isClosing else { return }
    do {
      let request = try exportRequest()
      guard request.capture.media.isImage, let url = request.capture.media.url else { return }
      let image = try CaptureCropExporter.image(at: url, crop: request.crop)
      pasteboard.clearContents()
      if pasteboard.writeObjects([NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))]) {
        imageCopyID = UUID()
      }
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func export(to url: URL) async throws {
    guard !isClosing else { throw CancellationError() }
    let request = try exportRequest()
    try await performExport {
      try await self.fileStore.saveExport(request, to: url)
    }
  }

  func saveToHistory(name: String) async throws {
    guard !isClosing, !isSaving else { throw CancellationError() }
    isSaving = true
    defer { isSaving = false }
    try await performExport {
      if !self.operation.isComplete {
        for await complete in Observations({ self.operation.isComplete }) where complete {
          break
        }
      }
      let request = try self.exportRequest()
      try await self.fileStore.saveReview(
        request, name: name, history: self.history
      )
    }
  }

  private func performExport(_ operation: @escaping @MainActor () async throws -> Void) async throws {
    guard !isClosing else { throw CancellationError() }
    errorMessage = nil
    let id = UUID()
    // Begin retaining ready sources before another UI action can remove them.
    let task = Task.immediate { try await operation() }
    exports[id] = task
    defer { exports[id] = nil }
    do { try await task.value } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  /// New reads start immediately; cancelled readers remain owned until they finish.
  func loadPlayback() async {
    guard !isClosing, !Task.isCancelled,
          let capture = currentCapture,
          capture.media.isVideo, let url = capture.media.url else { return }
    let trim = trim
    await read(.playback) { await self.playback.load(url, trim: trim) }
  }

  func prepareDrag() async {
    guard !isClosing, !Task.isCancelled,
          let request = try? exportRequest() else { return }
    await read(.drag) { await self.dragExport.prepare(request, fileStore: self.fileStore) }
  }

  private func read(_ kind: Reader, operation: @escaping @MainActor () async -> Void) async {
    for read in readers.values where read.kind == kind {
      read.task.cancel()
    }
    let id = UUID()
    let task = Task {
      guard !Task.isCancelled else { return }
      await operation()
    }
    readers[id] = Read(kind: kind, task: task)
    defer { readers[id] = nil }
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  func makeDragItem(frame: CGRect) throws -> NSDraggingItem? {
    guard !isClosing else { return nil }
    do {
      let request = try exportRequest()
      if request.capture.media.isVideo { return dragExport.draggingItem(for: request, frame: frame) }
      let url = try fileStore.makeImageDrag(request)
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      item.setDraggingFrame(frame, contents: NSImage(contentsOf: url))
      return item
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func beginClosing() {
    guard !isClosing else { return }
    isClosing = true
    stopReaders()
  }

  private func stopReaders() {
    for read in readers.values {
      read.task.cancel()
    }
    playback.stop()
    dragExport.stop()
  }

  func close() async {
    if let closeTask { await closeTask.value
      return
    }
    beginClosing()
    let acceptedExports = Array(exports.values)
    let pendingReads = readers.values.map(\.task)
    let task = Task {
      for read in pendingReads {
        await read.value
      }
      for export in acceptedExports {
        _ = try? await export.value
      }
      await operation.close()
    }
    closeTask = task
    await task.value
  }
}

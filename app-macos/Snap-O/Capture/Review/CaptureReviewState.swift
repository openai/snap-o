import AppKit
import Foundation
import Observation

/// Owns review selection, edits, readers, and accepted exports for one batch.
@Observable
@MainActor
final class CaptureReviewState {
  let batch: any CaptureBatch
  let fileStore: FileStore
  let playback = CaptureReviewPlayback()
  let dragExport: CaptureReviewDragExport
  let hint = PreviewHint()
  private(set) var selectedItemID: UUID?
  private(set) var edits: [UUID: MediaEdits] = [:]
  private(set) var isClosing = false
  private(set) var isSaving = false
  private(set) var errorMessage: String?
  private(set) var imageCopyID: UUID?

  private let history: CaptureHistory
  private let protectionID = UUID()
  private var deletedHistoryIDs: Set<UUID> = []
  @ObservationIgnored private var historyTask: Task<Void, Never>?
  private enum Reader { case playback, drag }
  private struct Read {
    let kind: Reader
    let task: Task<Void, Never>
  }
  @ObservationIgnored private var readers: [UUID: Read] = [:]
  @ObservationIgnored private var exports: [UUID: Task<Void, Error>] = [:]
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(
    batch: any CaptureBatch, selectedDeviceID: String?, fileStore: FileStore,
    history: CaptureHistory, dragExport: CaptureReviewDragExport = CaptureReviewDragExport()
  ) {
    self.batch = batch
    self.fileStore = fileStore
    self.history = history
    self.dragExport = dragExport
    selectedItemID = batch.items.first { $0.device.id == selectedDeviceID }?.id ?? batch.items.first?.id
  }

  var items: [CaptureItem] {
    batch.items.filter { item in
      guard let media = item.media, let url = media.media.url,
            url.deletingLastPathComponent().deletingLastPathComponent().path == history.repository.root.path else { return true }
      return !deletedHistoryIDs.contains(media.id)
    }
  }

  var selectedItem: CaptureItem? { items.first { $0.id == selectedItemID } }
  var currentCapture: CaptureMedia? { selectedItem?.media }
  var mediaList: [CaptureMedia] { items.compactMap(\.media) }
  var selectedItemWasDeleted: Bool {
    selectedItemID != nil && selectedItem == nil
  }

  func start() {
    guard !isClosing, historyTask == nil else { return }
    historyTask = Task {
      var recordedSelection: UUID?
      for await _ in Observations({ self.historyInput }) {
        guard !Task.isCancelled else { return }
        await synchronizeHistory(recordedSelection: &recordedSelection)
      }
    }
  }

  func setVisible(_ visible: Bool) {
    guard !isClosing else { return }
    playback.setPaneVisible(visible)
  }

  func select(_ id: UUID) {
    guard !isClosing, selectedItemID != id, items.contains(where: { $0.id == id }) else { return }
    stopReaders()
    selectedItemID = id
    hint.show(available: items.count > 1, transient: true)
  }

  func selectNeighbor(offset: Int) {
    guard !items.isEmpty else { return }
    let index = items.firstIndex { $0.id == selectedItemID } ?? 0
    select(items[(index + offset + items.count) % items.count].id)
  }

  func crop(for id: UUID) -> CGRect { edits[id]?.crop ?? CaptureCropGeometry.fullImage }
  func trim(for id: UUID) -> CaptureTrimRange? { edits[id]?.trim }

  func setCrop(_ crop: CGRect, for id: UUID) {
    guard !isClosing, !isSaving, items.contains(where: { $0.id == id && $0.media != nil }) else { return }
    edits[id, default: MediaEdits()].crop = crop
  }

  func setTrim(_ range: CaptureTrimRange?, for id: UUID) {
    guard !isClosing, !isSaving, items.contains(where: { $0.id == id && $0.media != nil }) else { return }
    edits[id, default: MediaEdits()].trim = range
  }

  func exportRequest(for id: UUID) throws -> CaptureExportRequest {
    guard let capture = items.first(where: { $0.id == id })?.media else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return CaptureExportRequest(capture: capture, edits: edits[id] ?? MediaEdits())
  }

  func clearError() { errorMessage = nil }

  func copySelectedImage(to pasteboard: NSPasteboard = .general) throws {
    guard !isClosing, let selectedItemID else { return }
    do {
      let request = try exportRequest(for: selectedItemID)
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

  func exportSelected(to url: URL) async throws {
    guard !isClosing, let selectedItemID else { throw CancellationError() }
    let request = try exportRequest(for: selectedItemID)
    try await performExport {
      try await self.fileStore.saveExport(request, to: url)
    }
  }

  func saveToHistory(name: String) async throws {
    guard !isClosing, !isSaving else { throw CancellationError() }
    isSaving = true
    let selection = selectedItemID
    defer { isSaving = false }
    try await performExport {
      if !self.batch.isComplete {
        for await complete in Observations({ self.batch.isComplete }) where complete { break }
      }
      let requests = try self.items.filter { $0.media != nil }.map { try self.exportRequest(for: $0.id) }
      guard !requests.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
      let selectedMediaID = self.items.first { $0.id == selection }?.media?.id
      try await self.fileStore.saveReview(
        requests, name: name, selectedID: selectedMediaID, history: self.history.repository
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

  /// New selections start immediately; cancelled readers remain owned until they finish.
  func loadPlayback(for id: UUID) async {
    guard !isClosing, !Task.isCancelled, selectedItemID == id,
          let capture = items.first(where: { $0.id == id })?.media,
          capture.media.isVideo, let url = capture.media.url else { return }
    let trim = trim(for: id)
    await read(.playback) { await self.playback.load(url, trim: trim) }
  }

  func prepareDrag(for id: UUID) async {
    guard !isClosing, !Task.isCancelled, selectedItemID == id,
          let request = try? exportRequest(for: id) else { return }
    await read(.drag) { await self.dragExport.prepare(request, fileStore: self.fileStore) }
  }

  private func read(_ kind: Reader, operation: @escaping @MainActor () async -> Void) async {
    for read in readers.values where read.kind == kind { read.task.cancel() }
    let id = UUID()
    let task = Task {
      guard !Task.isCancelled else { return }
      await operation()
    }
    readers[id] = Read(kind: kind, task: task)
    defer { readers[id] = nil }
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  func makeDragItem(for id: UUID, frame: CGRect) throws -> NSDraggingItem? {
    guard !isClosing else { return nil }
    do {
      let request = try exportRequest(for: id)
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
    hint.cancel()
  }

  private func stopReaders() {
    for read in readers.values { read.task.cancel() }
    playback.stop()
    dragExport.stop()
  }

  func close() async {
    if let closeTask { await closeTask.value; return }
    beginClosing()
    let acceptedExports = Array(exports.values)
    let pendingReads = readers.values.map(\.task)
    let task = Task {
      for read in pendingReads { await read.value }
      for export in acceptedExports { _ = try? await export.value }
      await batch.close()
      historyTask?.cancel()
      await historyTask?.value
      await history.repository.protect([], owner: protectionID)
    }
    closeTask = task
    await task.value
  }

  private struct HistoryInput: Equatable {
    let sourceIDs: Set<UUID>
    let selectedID: UUID?
    let entries: [CaptureHistoryEntry]
  }

  private var historyInput: HistoryInput {
    HistoryInput(
      sourceIDs: Set(batch.items.compactMap { $0.media?.id }),
      selectedID: currentCapture?.id, entries: history.entries
    )
  }

  private func synchronizeHistory(recordedSelection: inout UUID?) async {
    while !Task.isCancelled {
      let input = historyInput
      await history.repository.protect(input.sourceIDs, owner: protectionID)
      let snapshot = await history.repository.currentSnapshot()
      guard !Task.isCancelled else { return }
      guard input == historyInput else { continue }
      let available = Set(snapshot.entries.flatMap { $0.items.compactMap(\.captureID) })
      deletedHistoryIDs = input.sourceIDs.subtracting(available)
      let selectedID = currentCapture?.id
      if selectedID != recordedSelection {
        recordedSelection = selectedID
        if let selectedID {
          await history.repository.recordCapturePaneSelection(selectedID)
        }
      }
      if input == historyInput { return }
    }
  }
}

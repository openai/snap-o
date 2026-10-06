import AppKit
@preconcurrency import AVFoundation
import Dependencies
import Observation

@MainActor
@Observable
final class CaptureReviewDragExport {
  typealias Preparation = @MainActor (CaptureExportRequest, URL) async throws -> NSImage

  private(set) var isPreparing = false
  private(set) var errorMessage: String?
  private var request: CaptureExportRequest?
  private var fileURL: URL?
  private var preview: NSImage?
  @Dependency(\.continuousClock)
  @ObservationIgnored private var clock
  @ObservationIgnored private var fileStore: FileStore?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var wasDragged = false
  @ObservationIgnored private let prepareFile: Preparation

  init(prepareFile: @escaping Preparation = CaptureReviewDragExport.exportFile) {
    self.prepareFile = prepareFile
  }

  func prepare(_ request: CaptureExportRequest, fileStore: FileStore) async {
    stop()
    let token = generation
    self.request = request
    self.fileStore = fileStore
    isPreparing = request.capture.media.isVideo
    guard isPreparing else { return }
    defer { if token == generation { isPreparing = false } }

    var destination: URL?
    do {
      try await fileStore.withRetainedSources([request]) { retained in
        // Retain before the debounce; review or History can be discarded while waiting.
        if request.crop != CaptureCropGeometry.fullImage {
          try await clock.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        guard token == generation else { return }
        let url = try fileStore.makeUniqueDragDestination(capturedAt: request.capture.media.capturedAt, kind: .video)
        destination = url
        let image = try await prepareFile(retained[0], url)
        try Task.checkCancellation()
        guard token == generation else {
          fileStore.discardTemporaryFile(at: url)
          return
        }
        fileURL = url
        preview = image
      }
    } catch {
      if let destination { fileStore.discardTemporaryFile(at: destination) }
      guard !Task.isCancelled, token == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  func stop() {
    generation = UUID()
    if !wasDragged, let fileURL { fileStore?.discardTemporaryFile(at: fileURL) }
    fileStore = nil
    request = nil
    fileURL = nil
    preview = nil
    wasDragged = false
    isPreparing = false
    errorMessage = nil
  }

  func isReady(for request: CaptureExportRequest) -> Bool {
    self.request == request && fileURL != nil && preview != nil
  }

  func draggingItem(for request: CaptureExportRequest, frame: CGRect) -> NSDraggingItem? {
    guard self.request == request, let fileURL, let preview else { return nil }
    // Keep completed exports alive after the review closes so receivers can read them.
    wasDragged = true
    let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
    item.setDraggingFrame(frame, contents: preview)
    return item
  }

  private static func exportFile(
    _ request: CaptureExportRequest,
    to destination: URL
  ) async throws -> NSImage {
    _ = try await CaptureCropExporter.export(request, to: destination)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 640)
    let image = try await generator.image(at: .zero).image
    return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
  }
}

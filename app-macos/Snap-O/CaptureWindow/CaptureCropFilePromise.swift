import AppKit
import UniformTypeIdentifiers

@MainActor
final class CaptureCropFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
  private let capture: CaptureMedia
  private let crop: CGRect

  init(capture: CaptureMedia, crop: CGRect) {
    self.capture = capture
    self.crop = crop
    super.init()
    fileType = capture.media.isImage ? UTType.png.identifier : UTType.mpeg4Movie.identifier
    delegate = self
  }

  func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
    FileStore.exportFilename(capturedAt: capture.media.capturedAt, kind: capture.media.isImage ? .image : .video)
  }

  func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
    .main
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    // AppKit permits asynchronous completion but does not annotate this callback Sendable.
    nonisolated(unsafe) let completion = completionHandler
    Task { [capture, crop] in
      do {
        _ = try await CaptureCropExporter.export(capture, crop: crop, to: url)
        completion(nil)
      } catch {
        completion(error)
      }
    }
  }
}

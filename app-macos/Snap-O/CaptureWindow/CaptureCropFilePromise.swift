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
    let completion = Completion(handler: completionHandler)
    Task { [capture, crop] in
      do {
        _ = try await CaptureCropExporter.export(capture, crop: crop, to: url)
        await completion.call(nil)
      } catch {
        await completion.call(error)
      }
    }
  }

  /// AppKit's callback lacks Sendable; invoke it only on its requested main queue.
  private struct Completion: @unchecked Sendable {
    let handler: (Error?) -> Void

    @MainActor
    func call(_ error: Error?) {
      handler(error)
    }
  }
}

import Foundation

extension FileStore {
  @MainActor
  func withRetainedSource<Result>(
    _ request: CaptureExportRequest,
    operation: @MainActor (CaptureExportRequest) async throws -> Result
  ) async throws -> Result {
    guard let source = request.capture.media.url else { throw CocoaError(.fileReadUnsupportedScheme) }
    return try await withRetainedFiles([source]) { urls in
      try await operation(request.replacingSource(with: urls[0]))
    }
  }

  @MainActor
  func saveExport(_ request: CaptureExportRequest, to destination: URL) async throws {
    try await withRetainedSource(request) { retained in
      try await CaptureCropExporter.save(retained, to: destination)
    }
  }

  @MainActor
  func saveReview(_ request: CaptureExportRequest, name: String, history: CaptureHistoryRepository) async throws {
    try await withRetainedSource(request) { retained in
      try Task.checkCancellation()
      let capture = retained.capture
      guard let kind = capture.media.saveKind else { throw CocoaError(.fileReadUnsupportedScheme) }
      let destination = makePreviewDestination(deviceID: capture.device.id, capturedAt: capture.media.capturedAt, kind: kind)
      defer { discardTemporaryFile(at: destination) }
      let exported = try await CaptureCropExporter.export(retained, to: destination)
      try Task.checkCancellation()
      try await history.saveReviewedCaptures([exported], name: name, selectedID: nil)
    }
  }

  func saveFile(at source: URL, to destination: URL) throws {
    try withRetainedFiles([source]) { sources in
      let fileExport = try StagedFileExport(to: destination)
      defer { fileExport.cleanup() }
      try FileManager.default.copyItem(at: sources[0], to: fileExport.url)
      try fileExport.commit()
    }
  }

  func saveImage(at source: URL, crop: CGRect, to destination: URL) throws {
    try withRetainedFiles([source]) { sources in
      try CaptureCropExporter.saveImage(at: sources[0], crop: crop, to: destination)
    }
  }

  func makeImageDrag(_ request: CaptureExportRequest) throws -> URL {
    guard request.capture.media.isImage, let source = request.capture.media.url else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    return try withRetainedFiles([source]) { sources in
      let destination = try makeUniqueDragDestination(capturedAt: request.capture.media.capturedAt, kind: .image)
      do {
        _ = try CaptureCropExporter.exportImage(at: sources[0], crop: request.crop, to: destination)
        return destination
      } catch {
        discardTemporaryFile(at: destination)
        throw error
      }
    }
  }
}

import Foundation

extension FileStore {
  @MainActor
  func withRetainedSources<Result>(
    _ requests: [CaptureExportRequest],
    operation: @MainActor ([CaptureExportRequest]) async throws -> Result
  ) async throws -> Result {
    let sources = try requests.map { request in
      guard let url = request.capture.media.url else { throw CocoaError(.fileReadUnsupportedScheme) }
      return url
    }
    return try await withRetainedFiles(sources) { urls in
      try await operation(zip(requests, urls).map { $0.replacingSource(with: $1) })
    }
  }

  @MainActor
  func saveExport(_ request: CaptureExportRequest, to destination: URL) async throws {
    try await withRetainedSources([request]) { requests in
      try await CaptureCropExporter.save(requests[0], to: destination)
    }
  }

  @MainActor
  func saveReview(
    _ requests: [CaptureExportRequest], name: String, selectedID: UUID?, history: CaptureHistoryRepository
  ) async throws {
    try await withRetainedSources(requests) { retained in
      var exports: [CaptureMedia] = []
      defer { discardPreviews(exports) }
      for request in retained {
        try Task.checkCancellation()
        let capture = request.capture
        guard let kind = capture.media.saveKind else { throw CocoaError(.fileReadUnsupportedScheme) }
        let destination = makePreviewDestination(deviceID: capture.device.id, capturedAt: capture.media.capturedAt, kind: kind)
        try await exports.append(CaptureCropExporter.export(request, to: destination))
      }
      try Task.checkCancellation()
      try await history.saveReviewedCaptures(exports, name: name, selectedID: selectedID)
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

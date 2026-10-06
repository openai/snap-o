@preconcurrency import AVFoundation
import CoreData
import Dependencies
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureCropExporter {
  static func save(_ request: CaptureExportRequest, to destination: URL) async throws {
    let fileExport = try StagedFileExport(to: destination)
    defer { fileExport.cleanup() }
    _ = try await export(request, to: fileExport.url)
    try fileExport.commit()
  }

  static func saveImage(at source: URL, crop: CGRect, to destination: URL) throws {
    let fileExport = try StagedFileExport(to: destination)
    defer { fileExport.cleanup() }
    _ = try exportImage(at: source, crop: crop, to: fileExport.url)
    try fileExport.commit()
  }

  static func pixelRect(_ crop: CGRect, size: CGSize, alignment: CGFloat = 1) -> CGRect {
    VideoExportSettings.pixelRect(crop, size: size, alignment: alignment)
  }

  static func image(at url: URL, crop: CGRect) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let result = image.cropping(to: pixelRect(crop, size: CGSize(width: image.width, height: image.height))) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return result
  }

  static func exportImage(at source: URL, crop: CGRect, to destination: URL) throws -> CGSize {
    let image = try image(at: source, crop: crop)
    guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    return CGSize(width: image.width, height: image.height)
  }

  static func export(
    _ request: CaptureExportRequest,
    to destination: URL
  ) async throws -> CaptureMedia {
    let capture = request.capture
    let crop = request.crop
    let trim = request.trim
    guard let source = capture.media.url else { throw CocoaError(.fileReadUnsupportedScheme) }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let size: CGSize
    do {
      if crop == CaptureCropGeometry.fullImage, trim == nil {
        try FileManager.default.copyItem(at: source, to: destination)
        size = capture.media.size
      } else if capture.media.isImage {
        size = try exportImage(at: source, crop: crop, to: destination)
      } else {
        size = try await exportVideo(at: source, crop: crop, trim: trim, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    let data = MediaCommon(
      capturedAt: capture.media.capturedAt,
      display: DisplayInfo(size: size, densityScale: capture.media.densityScale)
    )
    return CaptureMedia(
      id: capture.id,
      device: capture.device,
      media: capture.media.isImage ? .image(url: destination, data: data) : .video(url: destination, data: data)
    )
  }

  private static func exportVideo(at source: URL, crop: CGRect, trim: CaptureTrimRange? = nil, to destination: URL) async throws -> CGSize {
    @Dependency(\.videoFiles)
    var videoFiles
    let info = try await videoFiles.inspect(source)
    let timeRange: CMTimeRange?
    if let trim {
      guard trim.isValid(for: info.duration) else { throw CocoaError(.validationMissingMandatoryProperty) }
      timeRange = CMTimeRange(
        start: CMTime(seconds: trim.start, preferredTimescale: 60000),
        end: CMTime(seconds: trim.end, preferredTimescale: 60000)
      )
    } else {
      timeRange = nil
    }
    let settings = VideoExportSettings(info: info, crop: crop, timeRange: timeRange)
    try await videoFiles.export(source, settings, destination)
    return settings.size
  }
}

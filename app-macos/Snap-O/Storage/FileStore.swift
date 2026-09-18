import Foundation

private let log = SnapOLog.storage

final class FileStore: Sendable {
  private let baseDir: URL
  private let frameExportHandler: (@MainActor @Sendable (URL, String, CGSize) -> Void)?

  init(
    baseDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Snap-O", isDirectory: true),
    frameExportHandler: (@MainActor @Sendable (URL, String, CGSize) -> Void)? = nil
  ) {
    self.baseDir = baseDir
    self.frameExportHandler = frameExportHandler
    purgeExistingFiles()
  }

  @MainActor
  func recordExportedFrame(url: URL, deviceID: String, size: CGSize) {
    frameExportHandler?(url, deviceID, size)
  }

  func purgeExistingFiles() {
    do {
      if FileManager.default.fileExists(atPath: baseDir.path) {
        try FileManager.default.removeItem(at: baseDir)
      }
    } catch {
      log.error("Failed to delete previous files: \(error.localizedDescription)")
    }
  }

  func makePreviewDestination(
    deviceID: String,
    capturedAt: Date,
    kind: MediaSaveKind
  ) -> URL {
    let filename = makeDestination(prefix: deviceID, date: capturedAt, kind: kind).lastPathComponent
    let directory = baseDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(filename)
  }

  func makeDragDestination(capturedAt: Date, kind: MediaSaveKind) -> URL {
    makeDestination(prefix: "Snap-O", date: capturedAt, kind: kind)
  }

  static func exportFilename(capturedAt: Date, kind: MediaSaveKind, name: String? = nil) -> String {
    let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
    let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var basename = String(trimmedName.unicodeScalars.map { invalid.contains($0) ? "-" : Character($0) })
    let suffix = ".\(kind.fileExtension)"
    if basename.lowercased().hasSuffix(suffix) {
      basename.removeLast(suffix.count)
    }
    basename = basename.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    // Leave room for the extension within the filesystem's 255-byte filename limit.
    while basename.utf8.count > 240 {
      basename.removeLast()
    }
    if basename.isEmpty { basename = "Snap-O \(timestamp(from: capturedAt))" }
    return basename + suffix
  }

  func makeUniqueDragDestination(capturedAt: Date, kind: MediaSaveKind, name: String? = nil) throws -> URL {
    let filename = Self.exportFilename(capturedAt: capturedAt, kind: kind, name: name)
    let directory = baseDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(filename)
  }

  private func makeDestination(prefix: String, date: Date, kind: MediaSaveKind) -> URL {
    try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

    let timestamp = Self.timestamp(from: date)
    let fileExtension = kind.fileExtension

    let safePrefix = Self.sanitizeFilenameComponent(prefix)
    return baseDir.appendingPathComponent("\(safePrefix) \(timestamp).\(fileExtension)")
  }

  private static func timestamp(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .init(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter.string(from: date)
  }

  // MARK: - Filename sanitization

  private static func sanitizeFilenameComponent(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    var out = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    while out.contains("--") {
      out = out.replacingOccurrences(of: "--", with: "-")
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if out.isEmpty { out = "device" }
    if out.count > 80 { out = String(out.prefix(80)) }
    return out
  }
}

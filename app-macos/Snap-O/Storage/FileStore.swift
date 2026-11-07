import Darwin
import Foundation
import Synchronization

private let log = SnapOLog.storage

final class FileStore: Sendable {
  private struct ExportState {
    var isShuttingDown = false
    var activeCount = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let exports = Mutex(ExportState())
  private let baseDir: URL
  private let linkFile: @Sendable (URL, URL) throws -> Void
  private let frameExportHandler: (@MainActor @Sendable (CaptureMedia) -> Void)?

  init(
    baseDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Snap-O", isDirectory: true),
    linkFile: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) },
    frameExportHandler: (@MainActor @Sendable (CaptureMedia) -> Void)? = nil
  ) {
    self.baseDir = baseDir
    self.linkFile = linkFile
    self.frameExportHandler = frameExportHandler
    purgeExistingFiles()
  }

  @MainActor
  func recordExportedFrame(_ capture: CaptureMedia) {
    frameExportHandler?(capture)
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

  func discardPreviews(_ captures: [CaptureMedia]) {
    for capture in captures {
      if let url = capture.media.url { discardTemporaryFile(at: url) }
    }
  }

  func discardTemporaryFile(at url: URL) {
    let root = baseDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    // Never remove history entries or externally supplied files through draft cleanup.
    guard path.hasPrefix(root), FileManager.default.fileExists(atPath: path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      log.error("Failed to delete temporary capture: \(error.localizedDescription)")
    }
  }

  func beginShutdown() {
    exports.withLock { $0.isShuttingDown = true }
  }

  func shutdown() async {
    beginShutdown()
    await withCheckedContinuation { continuation in
      let isIdle = exports.withLock { state in
        if state.activeCount == 0 { return true }
        state.waiters.append(continuation)
        return false
      }
      if isIdle { continuation.resume() }
    }
  }

  func withExport<Result>(_ operation: () throws -> Result) throws -> Result {
    try beginExport()
    defer { finishExport() }
    return try operation()
  }

  @MainActor
  func withExport<Result>(_ operation: @MainActor () async throws -> Result) async throws -> Result {
    try Task.checkCancellation()
    try beginExport()
    defer { finishExport() }
    return try await operation()
  }

  private func beginExport() throws {
    try exports.withLock { state in
      guard !state.isShuttingDown else { throw CancellationError() }
      state.activeCount += 1
    }
  }

  private func finishExport() {
    let waiters = exports.withLock { state in
      state.activeCount -= 1
      guard state.activeCount == 0 else { return [CheckedContinuation<Void, Never>]() }
      let waiters = state.waiters
      state.waiters.removeAll()
      return waiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  func withRetainedFiles<Result>(_ sources: [URL], operation: ([URL]) throws -> Result) throws -> Result {
    try withExport {
      let retained = try retainFiles(sources)
      defer { try? FileManager.default.removeItem(at: retained.directory) }
      return try operation(retained.urls)
    }
  }

  @MainActor
  func withRetainedFiles<Result>(
    _ sources: [URL], operation: @MainActor ([URL]) async throws -> Result
  ) async throws -> Result {
    try await withExport {
      let retained = try retainFiles(sources)
      defer { try? FileManager.default.removeItem(at: retained.directory) }
      return try await operation(retained.urls)
    }
  }

  private func retainFiles(_ sources: [URL]) throws -> (directory: URL, urls: [URL]) {
    let manager = FileManager.default
    let directory = baseDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let urls = try sources.enumerated().map { index, source in
        let destination = directory.appendingPathComponent("\(index).\(source.pathExtension)")
        // Resolve symlinks so removing the original path cannot break a retained source.
        let source = source.resolvingSymlinksInPath()
        do {
          try linkFile(source, destination)
        } catch {
          try? manager.removeItem(at: destination)
          try manager.copyItem(at: source, to: destination)
        }
        return destination
      }
      return (directory, urls)
    } catch {
      try? manager.removeItem(at: directory)
      throw error
    }
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

  func makeDragCopy(of source: URL, capturedAt: Date, kind: MediaSaveKind, name: String? = nil) throws -> URL {
    try withRetainedFiles([source]) { sources in
      let destination = try makeUniqueDragDestination(capturedAt: capturedAt, kind: kind, name: name)
      do {
        // Copy-on-write keeps large recording drags inexpensive without sharing a mutable output.
        if clonefile(sources[0].path, destination.path, 0) != 0 {
          try FileManager.default.copyItem(at: sources[0], to: destination)
        }
        return destination
      } catch {
        discardTemporaryFile(at: destination)
        throw error
      }
    }
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

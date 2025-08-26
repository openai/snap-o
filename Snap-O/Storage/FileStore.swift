import Foundation

private let log = SnapOLog.storage

actor FileStore {
  private nonisolated let baseDir: URL

  init() {
    baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("Snap-O", isDirectory: true)
    purgeExistingFiles()
  }

  nonisolated func purgeExistingFiles() {
    do {
      if FileManager.default.fileExists(atPath: baseDir.path) {
        try FileManager.default.removeItem(at: baseDir)
      }
    } catch {
      log.error("Failed to delete previous files: \(error.localizedDescription)")
    }
  }

  nonisolated func makePreviewDestination(deviceID: String, kind: MediaKind) -> URL {
    makeDestination(prefix: deviceID, date: Date(), kind: kind)
  }

  nonisolated func makeDragDestination(capturedAt: Date, kind: MediaKind) -> URL {
    makeDestination(prefix: "Snap-O", date: capturedAt, kind: kind)
  }

  private nonisolated func makeDestination(prefix: String, date: Date, kind: MediaKind) -> URL {
    try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

    let timestamp = Self.tsFormatter.string(from: date)
    let fileExtension = fileExtension(kind)

    return baseDir.appendingPathComponent(
      "\(prefix) \(timestamp).\(fileExtension)"
    )
  }

  private nonisolated func fileExtension(_ kind: MediaKind) -> String {
    switch kind {
    case .image: "png"
    case .video: "mp4"
    }
  }

  private static let tsFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .init(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter
  }()
}

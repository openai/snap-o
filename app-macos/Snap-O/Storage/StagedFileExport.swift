import Foundation

struct StagedFileExport {
  let url: URL
  private let directory: URL
  private let destination: URL

  init(to destination: URL) throws {
    self.destination = destination
    // The save panel grants access to the file, not its parent directory.
    directory = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
    )
    url = directory.appendingPathComponent(destination.lastPathComponent)
  }

  func commit() throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: url)
    } else {
      try FileManager.default.moveItem(at: url, to: destination)
    }
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}

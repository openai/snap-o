import Foundation

enum SaveLocation {
  private static let lastHARExportDirectoryKey = "lastHARExportDirectory"

  static func defaultDirectory(for kind: MediaSaveKind) -> URL {
    if let existing = UserDefaults.standard.url(forKey: lastDirectoryKey(for: kind)) {
      return existing
    }
    switch kind {
    case .image:
      return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    case .video:
      return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    }
  }

  static func setLastDirectoryURL(_ url: URL, for kind: MediaSaveKind) {
    UserDefaults.standard.set(url, forKey: lastDirectoryKey(for: kind))
  }

  static func defaultHARExportDirectory() -> URL {
    if let existing = UserDefaults.standard.url(forKey: lastHARExportDirectoryKey),
       isDirectory(existing) {
      return existing
    }
    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  static func setLastHARExportDirectoryURL(_ url: URL) {
    UserDefaults.standard.set(url, forKey: lastHARExportDirectoryKey)
  }

  private static func lastDirectoryKey(for kind: MediaSaveKind) -> String {
    switch kind {
    case .image: "lastImageSaveDir"
    case .video: "lastVideoSaveDir"
    }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

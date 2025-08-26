import Foundation

enum SaveLocation {
  static func defaultDirectory(for kind: MediaKind) -> URL {
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

  static func setLastDirectoryURL(_ url: URL, for kind: MediaKind) {
    UserDefaults.standard.set(url, forKey: lastDirectoryKey(for: kind))
  }

  private static func lastDirectoryKey(for kind: MediaKind) -> String {
    switch kind {
    case .image: "lastImageSaveDir"
    case .video: "lastVideoSaveDir"
    }
  }
}

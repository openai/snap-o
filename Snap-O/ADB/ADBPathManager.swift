import AppKit
import SwiftUI

actor ADBPathManager {
  // Static so static funcs can use it without hard-coding the string.
  private static let bookmarkKey = "adbBookmark"

  nonisolated static func lastKnownADBURL() -> URL? {
    var isStale = false
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    if let url = try? URL(
      resolvingBookmarkData: data,
      options: .withSecurityScope,
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) {
      return url
    }
    return nil
  }

  @MainActor
  func promptForADBPath() {
    let panel = NSOpenPanel()
    panel.title = "Select adb"
    panel.message = "Select the adb binary from the Android SDK."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    let defaultPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Android/sdk/platform-tools", isDirectory: true)
    panel.directoryURL = defaultPath

    if panel.runModal() == .OK, let url = panel.url {
      do {
        let bookmark = try url.bookmarkData(
          options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
      } catch {
        SnapOLog.adb.error("Failed to create adb bookmark: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

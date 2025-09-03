import AppKit
import SwiftUI

actor ADBService {
  private var adbURL: URL?
  private var configurationWaiters: [CheckedContinuation<Void, Never>] = []

  init(defaultURL: URL? = ADBPathManager.lastKnownADBURL()) {
    adbURL = defaultURL
  }

  // Configuration/UI
  func ensureConfigured() async {
    if adbURL == nil {
      await promptForPath()
      await awaitConfigured()
    }
  }

  func promptForPath() async {
    let mgr = ADBPathManager()
    await MainActor.run { mgr.promptForADBPath() }
    let chosen = ADBPathManager.lastKnownADBURL()
    setURL(chosen)
  }

  // State API merged from previous client
  func setURL(_ newURL: URL?) {
    adbURL = newURL
    if let url = newURL, FileManager.default.fileExists(atPath: url.path) {
      let waiters = configurationWaiters
      configurationWaiters.removeAll()
      for w in waiters { w.resume() }
    }
  }

  func currentURL() -> URL? { adbURL }

  func awaitConfigured() async {
    if let url = adbURL, FileManager.default.fileExists(atPath: url.path) { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      configurationWaiters.append(continuation)
    }
  }

  func exec() throws -> ADBExec {
    guard let url = adbURL else { throw ADBError.adbNotFound }
    return ADBExec(url: url)
  }
}

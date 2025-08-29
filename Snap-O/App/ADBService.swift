import AppKit
import SwiftUI

@MainActor
final class ADBService {
  let client: ADBClient

  init(defaultURL: URL? = ADBPathManager.lastKnownADBURL()) {
    client = ADBClient(adbURL: defaultURL)
  }

  func ensureConfigured() async {
    if await client.currentURL() == nil {
      await promptForPath()
      await client.awaitConfigured()
    }
  }

  func promptForPath() async {
    let mgr = ADBPathManager()
    await MainActor.run {
      mgr.promptForADBPath()
    }
    let chosen = ADBPathManager.lastKnownADBURL()
    await client.setURL(chosen)
  }
}

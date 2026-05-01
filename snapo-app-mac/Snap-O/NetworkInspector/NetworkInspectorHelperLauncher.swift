import AppKit
import OSLog

@MainActor
enum NetworkInspectorHelperLauncher {
  private static let helperAppName = "Snap-O Network Inspector"
  private static let helperRelativePath = "Contents/Helpers/\(helperAppName).app"
  private nonisolated static let logger = Logger(subsystem: "com.openai.snapo", category: "NetworkInspectorHelper")

  static func open() {
    guard let helperURL = helperAppURL() else {
      showMissingHelperAlert()
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
      guard let error else { return }
      logger.error(
        "Failed to launch helper at \(helperURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      Task { @MainActor in
        showLaunchFailedAlert()
      }
    }
  }

  private static func helperAppURL() -> URL? {
    let helperURL = Bundle.main.bundleURL.appendingPathComponent(helperRelativePath)
    guard FileManager.default.fileExists(atPath: helperURL.path) else { return nil }
    return helperURL
  }

  private static func showMissingHelperAlert() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Network Inspector Unavailable"
    alert.informativeText = "Please try re-installing Snap-O."
    alert.runModal()
  }

  private static func showLaunchFailedAlert() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Unable to Launch Network Inspector"
    alert.informativeText = "Please try re-installing Snap-O."
    alert.runModal()
  }
}

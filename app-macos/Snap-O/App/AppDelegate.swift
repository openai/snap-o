import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  var prepareForTermination: (@Sendable () async -> Void)?

  var unfinishedTerminationWork: (@MainActor () -> [String])?
  private let termination = AppTermination()

  func applicationWillFinishLaunching(_ notification: Notification) {
    CommandDiagnostics.shared.start()
    NSWindow.allowsAutomaticWindowTabbing = false
    UserDefaults.standard.register(defaults: [
      "NSInitialToolTipDelay": 500
    ])
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    !flag
  }

  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    CommandDiagnostics.shared.record(
      "application-should-terminate replied=\(termination.outcome != nil) cleanupPending=\(termination.isRunning)"
    )
    if termination.outcome != nil { return .terminateNow }
    if termination.isRunning { return .terminateLater }
    guard CaptureReviewCloseGuard.prepareToClose() else { return .terminateCancel }

    AppSettings.shared.isAppTerminating = true
    let prepareForTermination = prepareForTermination
    let unfinishedWork = unfinishedTerminationWork
    termination.begin {
      await prepareForTermination?()
    } unfinishedWork: {
      unfinishedWork?() ?? []
    } reply: { result in
      if case .timedOut(let unfinished) = result {
        let pending = unfinished.isEmpty ? "none reported" : unfinished.joined(separator: ", ")
        CommandDiagnostics.shared.record("termination-cleanup-timeout unfinished=\(pending)")
        Perf.end(.appShutdown, finalLabel: "cleanup timeout: \(pending)")
      }
      CommandDiagnostics.shared.record("termination-reply allow=true")
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

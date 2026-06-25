import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  private static let terminationCleanupTimeoutSeconds = 5

  var prepareForTermination: (@Sendable () async -> Void)?

  private var terminationCleanupTask: Task<Void, Never>?
  private var terminationTimeoutTask: Task<Void, Never>?
  private var hasRepliedToTermination = false

  func applicationWillFinishLaunching(_ notification: Notification) {
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
    if hasRepliedToTermination { return .terminateNow }
    if terminationCleanupTask != nil { return .terminateLater }

    AppSettings.shared.isAppTerminating = true
    let prepareForTermination = prepareForTermination
    terminationCleanupTask = Task { [weak self] in
      await prepareForTermination?()
      self?.completeTermination(for: sender)
    }
    terminationTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.terminationCleanupTimeoutSeconds))
      guard !Task.isCancelled else { return }
      self?.completeTermination(for: sender)
    }
    return .terminateLater
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if UpdateCoordinator.shared.handle(url: url) { continue }
      if SnapOCommandCoordinator.shared.handle(url: url) { continue }
    }
  }

  private func completeTermination(for application: NSApplication) {
    guard !hasRepliedToTermination else { return }
    hasRepliedToTermination = true
    terminationCleanupTask?.cancel()
    terminationCleanupTask = nil
    terminationTimeoutTask?.cancel()
    terminationTimeoutTask = nil
    application.reply(toApplicationShouldTerminate: true)
  }
}

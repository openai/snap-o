import AppKit
import Foundation

actor ADBService {
  private struct PromptState {
    let task: Task<URL?, Never>
    var dismissHandler: (@MainActor () -> Void)?
    var wasAutoDismissed: Bool = false
  }

  private var adbURL: URL?
  private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
  private var promptState: PromptState?
  private var didCancelPrompt: Bool = false

  init(defaultURL: URL? = ADBPathManager.lastKnownADBURL()) {
    adbURL = defaultURL
  }

  // Configuration/UI
  func ensureConfigured() async {
    if validStoredURL() == nil {
      await promptForPath()
      await awaitConfigured()
    }
  }

  func promptForPath() async {
    _ = await promptForPathIfNeeded(forcePrompt: true)
  }

  // State API merged from previous client
  func setURL(_ newURL: URL?) {
    adbURL = newURL
    if let url = newURL, FileManager.default.fileExists(atPath: url.path) {
      didCancelPrompt = false
      let waiters = configurationWaiters
      configurationWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  func currentURL() -> URL? { adbURL }

  func awaitConfigured() async {
    if let url = adbURL, FileManager.default.fileExists(atPath: url.path) { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      configurationWaiters.append(continuation)
    }
  }

  func exec() -> ADBExec {
    ADBExec(
      pathResolver: { [weak self] in
        guard let self else { throw ADBError.adbNotFound }
        return try await pathForServerRestart()
      },
      serverObserver: { [weak self] in
        await self?.serverAvailable()
      }
    )
  }

  private func promptForPathIfNeeded(
    forcePrompt: Bool = false,
    waitForSelection: Bool = true
  ) async -> URL? {
    if let url = validStoredURL() { return url }
    if didCancelPrompt, !forcePrompt { return nil }

    if let currentPrompt = promptState {
      return waitForSelection ? await currentPrompt.task.value : nil
    }

    let currentURL = validStoredURL()
    let task = Task<URL?, Never> { [weak self, currentURL] in
      guard let self else { return currentURL }
      let chosen = await presentADBPrompt(forcePrompt: forcePrompt)
      let stored = await validStoredURL()
      return chosen ?? stored
    }
    promptState = PromptState(task: task, dismissHandler: nil, wasAutoDismissed: false)

    if !waitForSelection {
      Task { await handlePromptCompletion(task.value) }
      return nil
    }

    let result = await task.value
    await handlePromptCompletion(result)
    return result
  }

  private func requireADBURL() async throws -> URL {
    if let url = validStoredURL() { return url }
    if let resolved = await promptForPathIfNeeded(forcePrompt: true) { return resolved }
    throw ADBError.adbNotFound
  }

  private func pathForServerRestart() async throws -> URL {
    if let url = validStoredURL() { return url }
    if let resolved = await promptForPathIfNeeded(forcePrompt: false, waitForSelection: false) {
      return resolved
    }
    throw ADBError.adbNotFound
  }

  private func validStoredURL() -> URL? {
    guard let url = adbURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  func serverAvailable() async {
    didCancelPrompt = false
    promptState?.wasAutoDismissed = true
    await dismissActivePromptIfNeeded()
  }

  private func handlePromptCompletion(_ result: URL?) async {
    if result == nil, promptState?.wasAutoDismissed != true {
      didCancelPrompt = true
    }
    promptState = nil
  }

  private func dismissActivePromptIfNeeded() async {
    guard let handler = promptState?.dismissHandler else { return }
    promptState?.dismissHandler = nil
    await MainActor.run { handler() }
  }

  // Avoid forcing the app to activate while in the background; wait until the user returns.
  @MainActor
  private func waitForActiveApplicationIfNeeded() async {
    if NSApplication.shared.isActive { return }

    let notifications = NotificationCenter.default.notifications(
      named: NSApplication.didBecomeActiveNotification
    )

    for await _ in notifications where NSApplication.shared.isActive {
      break
    }
  }

  private func presentADBPrompt(forcePrompt: Bool) async -> URL? {
    let previouslyCancelled = didCancelPrompt
    if previouslyCancelled, !forcePrompt { return nil }

    return await withCheckedContinuation { continuation in
      Task { @MainActor [weak self] in
        guard let self else {
          continuation.resume(returning: nil)
          return
        }

        if await promptState?.wasAutoDismissed == true {
          continuation.resume(returning: nil)
          return
        }

        await waitForActiveApplicationIfNeeded()

        if await promptState?.wasAutoDismissed == true {
          continuation.resume(returning: nil)
          return
        }

        let presentation = await presentPromptUI()

        switch presentation.style {
        case .sheet(let window):
          let sheetWindow = presentation.alert.window
          await updatePromptDismissHandler {
            if let parent = sheetWindow.sheetParent {
              parent.endSheet(sheetWindow, returnCode: .abort)
            } else {
              sheetWindow.orderOut(nil)
            }
          }

          presentation.alert.beginSheetModal(for: window) { response in
            Task { await self.finishPrompt(response, continuation: continuation) }
          }

        case .modal:
          let response = presentation.alert.runModal()
          Task { await self.finishPrompt(response, continuation: continuation) }
        }
      }
    }
  }

  @MainActor
  private func presentPromptUI() async -> (alert: NSAlert, style: PresentationStyle) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Waiting for ADB server..."
    alert.informativeText = """
    You may need to start the ADB server with "adb start-server".
    Snap-O can do it automatically if you set your ADB path.
    """
    alert.addButton(withTitle: "Choose ADB Path…")
    alert.addButton(withTitle: "Cancel")

    if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
      return (alert, .sheet(window))
    }

    return (alert, .modal)
  }

  private func finishPrompt(
    _ response: NSApplication.ModalResponse,
    continuation: CheckedContinuation<URL?, Never>
  ) async {
    let result = await handlePromptResponse(response)
    continuation.resume(returning: result)
  }

  private func handlePromptResponse(_ response: NSApplication.ModalResponse) async -> URL? {
    await updatePromptDismissHandler(nil)

    guard response == .alertFirstButtonReturn else { return nil }

    let chosenURL = await MainActor.run { () -> URL? in
      let mgr = ADBPathManager()
      mgr.promptForADBPath()
      return ADBPathManager.lastKnownADBURL()
    }

    if let chosenURL { setURL(chosenURL) }
    return chosenURL
  }

  private func updatePromptDismissHandler(_ handler: (@MainActor () -> Void)?) async {
    if var state = promptState {
      state.dismissHandler = handler
      promptState = state
    }
  }

  private enum PresentationStyle {
    case sheet(NSWindow)
    case modal
  }
}

import AppKit
import Observation

@MainActor
@Observable
final class EmulatorClipboardSync {
  private(set) var isUnavailable = false
  @ObservationIgnored private var sessionID: UUID?
  @ObservationIgnored private var state = ClipboardSyncState()

  func run(serial: String) async {
    let id = UUID()
    sessionID = id
    let emulator = EmulatorClient()
    defer {
      emulator.close()
      if sessionID == id { stop() }
    }
    while isActive(id) {
      do {
        let endpoint = try await emulator.clipboardEndpoint(serial: serial)
        guard isActive(id) else { return }
        state = ClipboardSyncState()
        try await EmulatorClipboardTransport.connect(endpoint: endpoint) { transport in
          let previousText = try await transport.getText()
          guard isActive(id) else { return }
          let initialText = hostText()
          if let initialText {
            state.ignoreInitialSnapshot(matching: previousText)
            try await transport.setText(initialText)
          } else {
            receive(previousText, sessionID: id)
          }
          guard isActive(id) else { return }
          isUnavailable = false
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              try await transport.receive { [weak self] text in
                await self?.receive(text, sessionID: id)
              }
            }
            group.addTask { try await self.sendChanges(transport: transport, sessionID: id) }
            defer { group.cancelAll() }
            try await group.next()
          }
        }
      } catch {
        guard isActive(id) else { return }
        // Transport errors may contain metadata; never log clipboard text or authentication tokens.
        isUnavailable = true
      }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }

  func stop() {
    sessionID = nil
    isUnavailable = false
    state = ClipboardSyncState()
  }

  private func sendChanges(transport: EmulatorClipboardTransport, sessionID: UUID) async throws {
    while isActive(sessionID) {
      if let text = hostText() { try await transport.setText(text) }
      try await Task.sleep(for: .milliseconds(300))
    }
  }

  private func hostText() -> String? {
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount
    guard state.changeCount != changeCount else { return nil }
    return state.hostText(pasteboard.string(forType: .string), changeCount: changeCount)
  }

  private func receive(_ text: String, sessionID: UUID) {
    guard isActive(sessionID) else { return }
    let pasteboard = NSPasteboard.general
    guard state.shouldReceive(text, hostChangeCount: pasteboard.changeCount) else { return }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    state.received(text, changeCount: pasteboard.changeCount)
  }

  private func isActive(_ id: UUID) -> Bool {
    !Task.isCancelled && sessionID == id && AppSettings.shared.syncClipboard
  }
}

import AppKit
import Observation

@MainActor
@Observable
final class EmulatorClipboardSync {
  private(set) var isUnavailable = false
  private let settings: AppSettings
  @ObservationIgnored private var state = ClipboardSyncState()

  init(settings: AppSettings) {
    self.settings = settings
  }

  func run(serial: String) async {
    let emulator = EmulatorClient()
    defer { emulator.close() }
    while isActive {
      do {
        state = ClipboardSyncState()
        let endpoint = try await emulator.clipboardEndpoint(serial: serial)
        guard isActive else { return }
        try await EmulatorClipboardTransport.connect(endpoint: endpoint) { transport in
          try await synchronize(transport)
        }
      } catch {
        guard isActive else { return }
        // Transport errors may contain metadata; never log clipboard text or authentication tokens.
        isUnavailable = true
      }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }

  private func synchronize(_ transport: EmulatorClipboardTransport) async throws {
    let previousText = try await transport.getText()
    guard isActive else { return }
    if let initialText = hostText() {
      state.ignoreInitialSnapshot(matching: previousText)
      try await transport.setText(initialText)
    } else {
      receive(previousText)
    }
    guard isActive else { return }
    isUnavailable = false
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await transport.receive { text in await self.receive(text) }
      }
      group.addTask { try await self.sendChanges(transport: transport) }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  private func sendChanges(transport: EmulatorClipboardTransport) async throws {
    while isActive {
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

  private func receive(_ text: String) {
    guard isActive else { return }
    let pasteboard = NSPasteboard.general
    guard state.shouldReceive(text, hostChangeCount: pasteboard.changeCount) else { return }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    state.received(text, changeCount: pasteboard.changeCount)
  }

  private var isActive: Bool {
    !Task.isCancelled && settings.syncClipboard
  }
}

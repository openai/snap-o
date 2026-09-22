import AppKit
import Observation

@MainActor
@Observable
final class ClipboardSync {
  private(set) var isUnavailable = false
  private let settings: AppSettings
  private let pasteboard: NSPasteboard
  @ObservationIgnored private var state = ClipboardSyncState()

  init(settings: AppSettings, pasteboard: NSPasteboard = .general) {
    self.settings = settings
    self.pasteboard = pasteboard
  }

  func run(serial: String) async {
    let emulator = EmulatorClient()
    defer { emulator.close() }
    while isActive {
      do {
        state = ClipboardSyncState()
        if serial.hasPrefix("emulator-") {
          let endpoint = try await emulator.clipboardEndpoint(serial: serial)
          guard isActive else { return }
          let authentication = EmulatorClipboardAuthentication(endpoint: endpoint) {
            try await emulator.clipboardEndpoint(serial: serial)
          }
          try await EmulatorClipboardTransport.connect(authentication: authentication) { transport in
            try await synchronize(transport)
          }
        } else {
          try await DeviceClipboardTransport.connect(serial: serial) { transport in
            try await synchronize(transport)
          }
        }
      } catch {
        guard isActive else { return }
        // Transport errors may contain metadata; never log clipboard text or authentication tokens.
        isUnavailable = true
      }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }

  private func synchronize(_ transport: any ClipboardTransport) async throws {
    let previousText = try await transport.getText()
    guard isActive else { return }
    if let initialText = synchronizeInitialClipboard(with: previousText) {
      try await transport.setText(initialText)
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

  private func sendChanges(transport: any ClipboardTransport) async throws {
    while isActive {
      if let text = hostText() { try await transport.setText(text) }
      try await Task.sleep(for: .milliseconds(300))
    }
  }

  private func hostText() -> String? {
    let changeCount = pasteboard.changeCount
    guard state.changeCount != changeCount else { return nil }
    return state.hostText(pasteboard.string(forType: .string), changeCount: changeCount)
  }

  func receive(_ text: String) {
    guard isActive else { return }
    guard state.shouldReceive(text, hostChangeCount: pasteboard.changeCount) else { return }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    state.received(text, changeCount: pasteboard.changeCount)
  }

  func synchronizeInitialClipboard(with previousText: String) -> String? {
    let hasHostItems = pasteboard.pasteboardItems?.isEmpty == false
    let text = hostText()
    if hasHostItems {
      // The stream can repeat this snapshot; it must not replace unsupported Mac contents either.
      state.ignoreInitialSnapshot(matching: previousText)
    } else {
      receive(previousText)
    }
    return text
  }

  private var isActive: Bool {
    !Task.isCancelled && settings.syncClipboard
  }
}

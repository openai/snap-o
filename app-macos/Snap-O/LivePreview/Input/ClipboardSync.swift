import AppKit
import Dependencies
import Observation

@MainActor
@Observable
final class ClipboardSync {
  private(set) var isUnavailable = false
  private let settings: AppSettings
  private let pasteboard: any TextPasteboard
  private let maySynchronize: @MainActor () -> Bool
  @Dependency(\.continuousClock)
  @ObservationIgnored private var clock
  private let connect: @MainActor (
    DeviceTarget, @escaping @MainActor (any ClipboardTransport) async throws -> Void
  ) async throws -> Void
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private var target: DeviceTarget?
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var state = ClipboardSyncState()

  init(
    settings: AppSettings,
    pasteboard: any TextPasteboard = NSPasteboard.general,
    maySynchronize: @escaping @MainActor () -> Bool = { true },
    connect: @escaping @MainActor (
      DeviceTarget, @escaping @MainActor (any ClipboardTransport) async throws -> Void
    ) async throws -> Void
  ) {
    self.settings = settings
    self.pasteboard = pasteboard
    self.maySynchronize = maySynchronize
    self.connect = connect
  }

  func stop() {
    // Reject queued transport callbacks before its owner waits for the session task.
    isStopped = true
    operation?.cancel()
  }

  func run(target: DeviceTarget) async {
    guard !isStopped else { return }
    self.target = target
    let task = Task { await runConnection(target: target) }
    operation = task
    defer {
      isStopped = true
      operation = nil
    }
    let handler: UUID
    do {
      handler = try target.onInvalidation { task.cancel() }
    } catch {
      task.cancel()
      await task.value
      return
    }
    defer { target.removeInvalidationHandler(handler) }
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func runConnection(target: DeviceTarget) async {
    while isActive {
      do {
        state = ClipboardSyncState()
        try await connect(target) { transport in try await self.synchronize(transport) }
      } catch {
        guard isActive else { return }
        // Transport errors may contain metadata; never log clipboard text or authentication tokens.
        isUnavailable = true
      }
      do { try await clock.sleep(for: .seconds(3)) } catch { return }
    }
  }

  private func synchronize(_ transport: any ClipboardTransport) async throws {
    let previousText = try await transport.getText()
    guard isActive else { return }
    if maySynchronize(), let initialText = synchronizeInitialClipboard(with: previousText) {
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
      if maySynchronize(), let text = hostText() { try await transport.setText(text) }
      try await clock.sleep(for: .milliseconds(300))
    }
  }

  private func hostText() -> String? {
    let changeCount = pasteboard.changeCount
    guard state.changeCount != changeCount else { return nil }
    return state.hostText(pasteboard.text, changeCount: changeCount)
  }

  func receive(_ text: String) {
    guard isActive, maySynchronize() else { return }
    guard state.shouldReceive(text, hostChangeCount: pasteboard.changeCount) else { return }
    pasteboard.replaceText(text)
    state.received(text, changeCount: pasteboard.changeCount)
  }

  func synchronizeInitialClipboard(with previousText: String) -> String? {
    guard isActive, maySynchronize() else { return nil }
    let hasHostItems = pasteboard.hasItems
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
    !isStopped && !Task.isCancelled && target?.isValid != false && settings.syncClipboard
  }
}

import AppKit
#if canImport(Snap_O) && !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LivePreviewKeyboardTests {
  @Test
  func settingDefaultsOnAndPersistsIndependentlyOfClipboard() throws {
    let suite = "KeyboardTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.keyboardInput)
    settings.syncClipboard = false
    #expect(settings.keyboardInput)
    settings.keyboardInput = false
    #expect(!AppSettings(defaults: defaults).keyboardInput)
  }

  @Test
  func preservesOrderAndDropsPendingEventsOnStop() async throws {
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { _ in transport }
    keyboard.send(.text("a"))
    keyboard.send(.key(code: 67))
    keyboard.send(.paste("b"))
    try await transport.waitForCount(1)
    #expect(transport.events == [.text("a")])
    transport.finish()
    try await transport.waitForCount(2)
    #expect(transport.events == [.text("a"), .key(code: 67)])
    keyboard.stop()
    transport.finish()
    #expect(transport.isClosed)
    #expect(transport.events.count == 2)
  }

  @Test
  func unsupportedTextDoesNotDiscardLaterTyping() async throws {
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { _ in transport }
    defer { keyboard.stop() }
    keyboard.send(.text("😀"))
    keyboard.send(.text("a"))
    keyboard.send(.key(code: 67))
    try await transport.waitForCount(1)
    transport.finish(.unsupportedText)
    try await transport.waitForCount(2)
    #expect(keyboard.errorMessage != nil)
    #expect(!transport.isClosed)
    transport.finish()
    try await transport.waitForCount(3)
    #expect(keyboard.errorMessage == nil)
    #expect(transport.events == [.text("😀"), .text("a"), .key(code: 67)])
    transport.finish()
  }

  @Test
  func connectionFailureStopsQueuedInput() async throws {
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { _ in transport }
    defer { keyboard.stop() }
    keyboard.send(.text("a"))
    keyboard.send(.text("b"))
    try await transport.waitForCount(1)
    transport.fail()
    try await waitForState { keyboard.errorMessage != nil }
    #expect(transport.isClosed)
    #expect(transport.events == [.text("a")])
  }

  @Test(arguments: [false, true])
  func copyPreservesNewerLocalClipboard(newerCopy: Bool) async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("original", forType: .string)
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device", pasteboard: pasteboard) { _ in transport }
    defer { keyboard.stop() }
    keyboard.send(.copy)
    try await transport.waitForCount(1)
    if newerCopy {
      pasteboard.clearContents()
      pasteboard.setString("newer Mac copy", forType: .string)
    }
    transport.finish(.copied("Android selection"))
    // A second command starts only after the copy result has been handled.
    keyboard.send(.key(code: 21))
    try await transport.waitForCount(2)
    #expect(pasteboard.string(forType: .string) == (newerCopy ? "newer Mac copy" : "Android selection"))
    transport.finish()
  }

  @Test(arguments: [false, true])
  func preparesBeforeTypingAndPreservesNewFocusInput(staleRequestFails: Bool) async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("original", forType: .string)
    let transport = KeyboardTestTransport()
    let replacement = KeyboardTestTransport()
    let connections = TestValue(0)
    let keyboard = LivePreviewKeyboard(deviceID: "test-device", pasteboard: pasteboard) { _ in
      connections.value += 1
      return connections.value == 1 ? transport : replacement
    }
    defer { keyboard.stop() }
    keyboard.prepare()
    try await waitForState { connections.value > 0 }
    #expect(transport.events.isEmpty)
    keyboard.send(.copy)
    try await transport.waitForCount(1)
    keyboard.send(.text("discard"))
    keyboard.discardPendingInput()
    keyboard.send(.text("new focus"))
    if staleRequestFails {
      transport.fail()
      try await replacement.waitForCount(1)
      #expect(connections.value == 2 && transport.isClosed)
      #expect(transport.events == [.copy])
      #expect(replacement.events == [.text("new focus")])
      replacement.finish()
    } else {
      transport.finish(.copied("stale copy"))
      try await transport.waitForCount(2)
      #expect(connections.value == 1 && !transport.isClosed)
      #expect(transport.events == [.copy, .text("new focus")])
      transport.finish()
    }
    #expect(keyboard.errorMessage == nil)
    #expect(pasteboard.string(forType: .string) == "original")
  }

  @Test
  func cancelledConnectionCannotReplaceRestartedConnection() async throws {
    let first = KeyboardTestTransport()
    let second = KeyboardTestTransport()
    let delayedConnection = TestValue<CheckedContinuation<any LivePreviewKeyboardTransport, Never>?>(nil)
    let connections = TestValue(0)
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { deviceID in
      #expect(deviceID == "test-device")
      connections.value += 1
      if connections.value == 1 {
        return await withCheckedContinuation { delayedConnection.value = $0 }
      }
      return second
    }
    defer { keyboard.stop() }
    keyboard.prepare()
    try await waitForState { delayedConnection.value != nil }
    keyboard.stop()
    keyboard.send(.text("new focus"))
    try await second.waitForCount(1)
    delayedConnection.value?.resume(returning: first)
    try await first.waitUntilClosed()
    keyboard.send(.key(code: 67))
    second.finish()
    try await second.waitForCount(2)
    #expect(connections.value == 2)
    #expect(first.events.isEmpty)
    #expect(!second.isClosed)
    #expect(second.events == [.text("new focus"), .key(code: 67)])
    second.finish()
  }

  @Test
  func invalidatedConnectionRejectsLateSetup() async throws {
    let target = DeviceTarget(serial: "test-device", transportID: "1")
    let transport = KeyboardTestTransport()
    let setup = TestValue<CheckedContinuation<any LivePreviewKeyboardTransport, Never>?>(nil)
    let keyboard = LivePreviewKeyboard(deviceID: target.serial, target: target) { _ in
      await withCheckedContinuation { setup.value = $0 }
    }
    keyboard.send(.text("old connection"))
    try await waitForState { setup.value != nil }
    target.invalidate()
    setup.value?.resume(returning: transport)
    try await transport.waitUntilClosed()
    #expect(transport.events.isEmpty)
  }

  @Test
  func invalidatedConnectionCannotApplyCopyReply() async throws {
    let target = DeviceTarget(serial: "test-device", transportID: "1")
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Mac copy", forType: .string)
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: target.serial, target: target, pasteboard: pasteboard) { _ in transport }
    keyboard.send(.copy)
    keyboard.send(.text("queued"))
    try await transport.waitForCount(1)
    target.invalidate()
    transport.finish(.copied("stale reply"))
    try await transport.waitUntilClosed()
    #expect(transport.events == [.copy])
    #expect(pasteboard.string(forType: .string) == "Mac copy")
  }

  @Test
  func shutdownWaitsForInFlightInputAndRejectsItsLateCopy() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Mac copy", forType: .string)
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device", pasteboard: pasteboard) { _ in transport }
    keyboard.send(.copy)
    try await transport.waitForCount(1)
    let shutdown = keyboard.beginShutdown()
    let entered = TestValue(false)
    let completed = TestValue(false)
    let waiter = Task { entered.value = true
      await shutdown.value
      completed.value = true
    }
    try await waitForState { entered.value }
    #expect(transport.isClosed && !completed.value)
    keyboard.prepare()
    keyboard.send(.text("after shutdown"))
    transport.finish(.copied("late device copy"))
    await waiter.value
    await keyboard.beginShutdown().value
    #expect(completed.value && transport.events == [.copy])
    #expect(pasteboard.string(forType: .string) == "Mac copy")
  }

  @Test
  func focusReleaseJoinsOldInputWithoutClosingTheKeyboard() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Mac copy", forType: .string)
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device", pasteboard: pasteboard) { _ in transport }
    keyboard.send(.copy)
    keyboard.send(.text("discarded"))
    try await transport.waitForCount(1)
    let release = keyboard.releaseInput()
    let completed = TestValue(false)
    let entered = TestValue(false)
    let wait = Task { entered.value = true
      await release.value
      completed.value = true
    }
    try await waitForState { entered.value }
    #expect(!completed.value)
    transport.finish(.copied("Old window copy"))
    await wait.value
    #expect(pasteboard.string(forType: .string) == "Mac copy")
    #expect(transport.events == [.copy])
    #expect(!transport.isClosed)
    keyboard.send(.text("New window"))
    try await transport.waitForCount(2)
    #expect(transport.events == [.copy, .text("New window")])
    transport.finish()
    await keyboard.beginShutdown().value
  }

  @Test
  func wireFramesPreserveLiteralTextAndRejectOversize() throws {
    let text = "quotes '\"; $HOME `literal` %s\n😀"
    let bytes = Data(text.utf8)
    let frame = try DeviceKeyboardTransport.frame(.paste(text))
    #expect(frame.prefix(4) == Data([0, 0, 0, 3]))
    #expect(frame.dropFirst(8) == bytes)
    #expect(try DeviceKeyboardTransport.frame(.copy) == Data([0, 0, 0, 4]))
    #expect(try DeviceKeyboardTransport.frame(.key(code: 21, modifiers: 1)) == Data([0, 0, 0, 2, 0, 0, 0, 21, 0, 0, 0, 1]))
    #expect(throws: (any Error).self) {
      try DeviceKeyboardTransport.frame(.paste(String(repeating: "x", count: 1_048_577)))
    }
  }
}

private final class KeyboardTestTransport: LivePreviewKeyboardTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let changed = TestSignal()
  private var recorded: [LivePreviewKeyboardEvent] = []
  private var closed = false
  private var continuation: CheckedContinuation<LivePreviewKeyboardResponse, any Error>?

  var events: [LivePreviewKeyboardEvent] {
    lock.withLock { recorded }
  }

  var isClosed: Bool {
    lock.withLock { closed }
  }

  func send(_ event: LivePreviewKeyboardEvent) async throws -> LivePreviewKeyboardResponse {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        self.continuation = continuation
        recorded.append(event)
      }
      changed.signal()
    }
  }

  func close() {
    lock.withLock { closed = true }
    changed.signal()
  }

  func finish(_ response: LivePreviewKeyboardResponse = .sent) {
    complete(.success(response))
  }

  func fail() {
    complete(.failure(ADBError.protocolFailure("Test connection closed")))
  }

  private func complete(_ result: Result<LivePreviewKeyboardResponse, any Error>) {
    let saved = lock.withLock {
      let saved = continuation
      continuation = nil
      return saved
    }
    saved?.resume(with: result)
  }

  func waitUntilClosed() async throws {
    while true {
      let revision = changed.revision
      if isClosed { return }
      try await changed.wait(after: revision)
    }
  }

  func waitForCount(_ count: Int) async throws {
    while true {
      let revision = changed.revision
      if events.count >= count { return }
      try await changed.wait(after: revision)
    }
  }
}

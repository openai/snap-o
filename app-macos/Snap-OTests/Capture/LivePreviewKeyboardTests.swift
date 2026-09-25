import AppKit
@testable import Snap_O
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
  func preservesOrderAndDropsPendingEventsOnStop() async {
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { _ in transport }
    keyboard.send(.text("a"))
    keyboard.send(.key(code: 67))
    keyboard.send(.paste("b"))
    await transport.waitForCount(1)
    #expect(transport.events == [.text("a")])
    transport.finish()
    await transport.waitForCount(2)
    #expect(transport.events == [.text("a"), .key(code: 67)])
    keyboard.stop()
    transport.finish()
    await Task.yield()
    #expect(transport.isClosed)
    #expect(transport.events.count == 2)
  }

  @Test
  func unsupportedTextDoesNotDiscardLaterTyping() async {
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { _ in transport }
    defer { keyboard.stop() }
    keyboard.send(.text("😀"))
    keyboard.send(.text("a"))
    keyboard.send(.key(code: 67))
    await transport.waitForCount(1)
    transport.finish(.unsupportedText)
    await transport.waitForCount(2)
    #expect(keyboard.errorMessage != nil)
    #expect(!transport.isClosed)
    transport.finish()
    await transport.waitForCount(3)
    #expect(keyboard.errorMessage == nil)
    #expect(transport.events == [.text("😀"), .text("a"), .key(code: 67)])
    transport.finish()
  }

  @Test
  func connectionFailureStopsQueuedInput() async {
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { _ in transport }
    defer { keyboard.stop() }
    keyboard.send(.text("a"))
    keyboard.send(.text("b"))
    await transport.waitForCount(1)
    transport.fail()
    while keyboard.errorMessage == nil {
      await Task.yield()
    }
    #expect(transport.isClosed)
    #expect(transport.events == [.text("a")])
  }

  @Test(arguments: [false, true])
  func copyPreservesNewerLocalClipboard(newerCopy: Bool) async {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("original", forType: .string)
    let transport = KeyboardTestTransport()
    let keyboard = LivePreviewKeyboard(deviceID: "test-device", pasteboard: pasteboard) { _ in transport }
    defer { keyboard.stop() }
    keyboard.send(.copy)
    await transport.waitForCount(1)
    if newerCopy {
      pasteboard.clearContents()
      pasteboard.setString("newer Mac copy", forType: .string)
    }
    transport.finish(.copied("Android selection"))
    // A second command starts only after the copy result has been handled.
    keyboard.send(.key(code: 21))
    await transport.waitForCount(2)
    #expect(pasteboard.string(forType: .string) == (newerCopy ? "newer Mac copy" : "Android selection"))
    transport.finish()
  }

  @Test(arguments: [false, true])
  func preparesBeforeTypingAndPreservesNewFocusInput(staleRequestFails: Bool) async {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("original", forType: .string)
    let transport = KeyboardTestTransport()
    let replacement = KeyboardTestTransport()
    var connections = 0
    let keyboard = LivePreviewKeyboard(deviceID: "test-device", pasteboard: pasteboard) { _ in
      connections += 1
      return connections == 1 ? transport : replacement
    }
    defer { keyboard.stop() }
    keyboard.prepare()
    while connections == 0 {
      await Task.yield()
    }
    #expect(transport.events.isEmpty)
    keyboard.send(.copy)
    await transport.waitForCount(1)
    keyboard.send(.text("discard"))
    keyboard.discardPendingInput()
    keyboard.send(.text("new focus"))
    if staleRequestFails {
      transport.fail()
      while replacement.events.isEmpty, keyboard.errorMessage == nil {
        await Task.yield()
      }
      #expect(connections == 2 && transport.isClosed)
      #expect(transport.events == [.copy])
      #expect(replacement.events == [.text("new focus")])
      replacement.finish()
    } else {
      transport.finish(.copied("stale copy"))
      await transport.waitForCount(2)
      #expect(connections == 1 && !transport.isClosed)
      #expect(transport.events == [.copy, .text("new focus")])
      transport.finish()
    }
    #expect(keyboard.errorMessage == nil)
    #expect(pasteboard.string(forType: .string) == "original")
  }

  @Test
  func cancelledConnectionCannotReplaceRestartedConnection() async {
    let first = KeyboardTestTransport()
    let second = KeyboardTestTransport()
    var delayedConnection: CheckedContinuation<any LivePreviewKeyboardTransport, Never>?
    var connections = 0
    let keyboard = LivePreviewKeyboard(deviceID: "test-device") { deviceID in
      #expect(deviceID == "test-device")
      connections += 1
      if connections == 1 {
        return await withCheckedContinuation { delayedConnection = $0 }
      }
      return second
    }
    defer { keyboard.stop() }
    keyboard.prepare()
    while delayedConnection == nil {
      await Task.yield()
    }
    keyboard.stop()
    keyboard.send(.text("new focus"))
    await second.waitForCount(1)
    delayedConnection?.resume(returning: first)
    while !first.isClosed {
      await Task.yield()
    }
    keyboard.send(.key(code: 67))
    second.finish()
    await second.waitForCount(2)
    #expect(connections == 2)
    #expect(first.events.isEmpty)
    #expect(!second.isClosed)
    #expect(second.events == [.text("new focus"), .key(code: 67)])
    second.finish()
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
    }
  }

  func close() {
    lock.withLock { closed = true }
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

  func waitForCount(_ count: Int) async {
    while events.count < count {
      await Task.yield()
    }
  }
}

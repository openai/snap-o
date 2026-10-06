import AppKit
@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Observation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct SharedLivePreviewTests {
  @Test(arguments: [false, true])
  func hiddenPreviewStopsAndResumesWithoutFocus(hidePane: Bool) async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    attachment.setVisible(true)
    try await fixture.ready(attachment)
    attachment.setFocused(false)
    #expect(fixture.sources[0].stops == 0)
    if hidePane { attachment.setPaneVisible(false) } else { attachment.setVisible(false) }
    try await waitForState { fixture.owners[0].video.session == nil }
    #expect(fixture.sources[0].stops == 1)
    #expect(attachment.preview?.videoState == .idle)
    if hidePane { attachment.setPaneVisible(true) } else { attachment.setVisible(true) }
    try await fixture.ready(attachment)
    #expect(fixture.sources.count == 2)
    #expect(fixture.owners.count == 1)
    #expect(!attachment.acceptsInput)
    await fixture.close()
  }

  @Test
  func visibleWindowKeepsVideoUntilItCloses() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let first = fixture.service.attach(to: target)
    let second = fixture.service.attach(to: target)
    first.setVisible(true)
    second.setVisible(true)
    try await fixture.ready(first)
    first.setVisible(false)
    #expect(fixture.sources[0].stops == 0)
    await second.close()
    try await waitForState { fixture.owners[0].video.session == nil }
    #expect(fixture.sources[0].stops == 1)
    first.setVisible(true)
    try await fixture.ready(first)
    #expect(fixture.sources.count == 2)
    await fixture.close()
  }

  @Test
  func twoWindowsShareOneOwnerAndCloseIndependently() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let first = fixture.service.attach(to: target)
    let second = fixture.service.attach(to: target)
    try await fixture.ready(first)
    try await fixture.ready(second)
    #expect(fixture.owners.count == 1)
    #expect(first.id != second.id)
    let device = fixture.device(target)
    #expect(first.renderer(for: device, viewID: UUID())?.session === second.renderer(for: device, viewID: UUID())?.session)
    await first.close()
    #expect(first.preview == nil)
    #expect(second.preview?.inputReady == true)
    #expect(fixture.sources[0].stops == 0)
    await second.close()
    #expect(fixture.sources[0].stops == 1)
    await fixture.close()
  }

  @Test
  func lastCloseAndReattachWaitForSourceCleanup() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let cleanup = TestSuspension()
    fixture.sourceCleanup = cleanup
    let target = fixture.target()
    let first = fixture.service.attach(to: target)
    try await fixture.ready(first)
    let closed = TestValue(false)
    let firstClose = Task { await first.close()
      closed.value = true
    }
    await cleanup.waitUntilStarted()
    let secondClose = Task { await first.close() }
    fixture.sourceCleanup = nil
    let next = fixture.service.attach(to: target)
    #expect(!closed.value && next.preview == nil)
    #expect(fixture.owners.count == 1)
    firstClose.cancel()
    cleanup.resume()
    await firstClose.value
    await secondClose.value
    try await fixture.ready(next)
    #expect(fixture.owners.count == 2)
    #expect(fixture.sources[0].stops == 1)
    await first.close()
    #expect(fixture.sources[1].stops == 0)
    await fixture.close()
  }

  @Test
  func replacementConnectionDoesNotWaitForOldConnectionCleanup() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let cleanup = TestSuspension()
    fixture.sourceCleanup = cleanup
    let old = fixture.service.attach(to: fixture.target())
    try await fixture.ready(old)
    let closing = Task { await old.close() }
    await cleanup.waitUntilStarted()
    fixture.sourceCleanup = nil
    let replacement = fixture.service.attach(to: fixture.target())
    try await fixture.ready(replacement)
    #expect(fixture.owners.count == 2)
    cleanup.resume()
    await closing.value
    await fixture.close()
  }

  @Test
  func sameDeviceFocusKeepsKeyboardAndClipboardConnections() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let first = fixture.service.attach(to: target)
    let second = fixture.service.attach(to: target)
    try await fixture.focus(first)
    first.send(.text("first"))
    try await waitForState { fixture.keyboardConnections == 1 && fixture.clipboardConnections == 1 }
    try await fixture.keyboards[0].waitForEvents(1)
    second.setVisible(true)
    second.setFocused(true)
    #expect(!first.acceptsInput)
    try await waitForState { second.acceptsInput }
    first.setFocused(false)
    second.send(.text("second"))
    try await fixture.keyboards[0].waitForEvents(2)
    #expect(second.acceptsInput)
    #expect(fixture.keyboardConnections == 1 && fixture.clipboardConnections == 1)
    #expect(fixture.keyboards[0].events == [.text("first"), .text("second")])
    await fixture.close()
  }

  @Test
  func focusWaitsForOldCopyAndRejectsItsResult() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let first = fixture.service.attach(to: target)
    let second = fixture.service.attach(to: target)
    try await fixture.focus(first)
    let copy = TestSuspension()
    fixture.keyboards[0].holdCopy(copy)
    first.send(.copy)
    await copy.waitUntilStarted()
    second.setVisible(true)
    second.setFocused(true)
    #expect(!first.acceptsInput && !second.acceptsInput)
    copy.resume()
    try await waitForState { second.acceptsInput }
    #expect(fixture.pasteboard.text != "stale selection")
    await fixture.close()
  }

  @Test
  func aNewFocusRequestDoesNotWaitForAnotherDevicePreparation() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let pending = TestSuspension()
    fixture.preparationGate = pending
    let waiting = fixture.service.attach(to: fixture.target("waiting"))
    waiting.setVisible(true)
    waiting.setFocused(true)
    await pending.waitUntilStarted()
    fixture.preparationGate = nil
    let ready = fixture.service.attach(to: fixture.target("ready"))
    try await fixture.focus(ready)
    #expect(!waiting.acceptsInput)
    pending.resume()
    try await fixture.ready(waiting)
    #expect(ready.acceptsInput && !waiting.acceptsInput)
    await fixture.close()
  }

  @Test
  func closingOldWindowDoesNotWaitForNextDevicesPreparation() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let first = fixture.service.attach(to: fixture.target("first"))
    try await fixture.focus(first)
    let pending = TestSuspension()
    fixture.preparationGate = pending
    let next = fixture.service.attach(to: fixture.target("next"))
    next.setVisible(true)
    next.setFocused(true)
    await pending.waitUntilStarted()
    await first.close()
    #expect(first.isClosed && !next.acceptsInput)
    pending.resume()
    try await waitForState { next.acceptsInput }
    await fixture.close()
  }

  @Test
  func leavingTextResponderKeepsWindowInputAndRejectsLateCopy() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let first = fixture.service.attach(to: fixture.target())
    try await fixture.focus(first)
    try await waitForState { fixture.keyboardConnections == 1 && fixture.clipboardConnections == 1 }
    let copy = TestSuspension()
    fixture.keyboards[0].holdCopy(copy)
    first.send(.copy)
    await copy.waitUntilStarted()
    first.discardPendingInput()
    first.stop()
    #expect(first.acceptsInput)
    copy.resume()
    first.prepare()
    first.send(.text("after text focus"))
    try await fixture.keyboards[0].waitForEvents(2)
    #expect(fixture.pasteboard.text != "stale selection")
    #expect(fixture.keyboardConnections == 1 && fixture.clipboardConnections == 1)
    await fixture.close()
  }

  @Test
  func oldKeyboardTeardownDoesNotCancelNewWindowsCopy() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let old = fixture.service.attach(to: target)
    let current = fixture.service.attach(to: target)
    try await fixture.focus(old)
    try await fixture.focus(current)
    let copy = TestSuspension()
    fixture.keyboards[0].holdCopy(copy)
    current.send(.copy)
    await copy.waitUntilStarted()
    old.discardPendingInput()
    old.stop()
    copy.resume()
    current.send(.text("copy finished"))
    try await fixture.keyboards[0].waitForEvents(2)
    #expect(fixture.pasteboard.text == "stale selection")
    #expect(current.acceptsInput)
    await fixture.close()
  }

  @Test
  func changingDevicesWaitsForClipboardCleanupAndRejectsLateMessages() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let cleanup = TestSuspension()
    fixture.clipboardCleanup = cleanup
    let old = fixture.service.attach(to: fixture.target("old"))
    try await fixture.focus(old)
    try await waitForState { fixture.clipboards.count == 1 }
    await fixture.clipboards[0].waitUntilReceiving()
    fixture.clipboardCleanup = nil
    let current = fixture.service.attach(to: fixture.target("current"))
    current.setVisible(true)
    current.setFocused(true)
    await cleanup.waitUntilStarted()
    #expect(!old.acceptsInput && !current.acceptsInput)
    #expect(fixture.clipboardConnections == 1)
    await fixture.clipboards[0].deliver("from old device")
    #expect(fixture.pasteboard.text != "from old device")
    cleanup.resume()
    try await waitForState { current.acceptsInput && fixture.clipboards.count == 2 }
    await fixture.clipboards[1].waitUntilReceiving()
    await fixture.clipboards[1].deliver("from current device")
    #expect(fixture.pasteboard.text == "from current device")
    #expect(fixture.clipboardConnections == 2)
    await fixture.close()
  }

  @Test
  func invalidationImmediatelyRejectsInputAndClosesAllUsers() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let first = fixture.service.attach(to: target)
    let second = fixture.service.attach(to: target)
    try await fixture.focus(first)
    try await waitForState { fixture.keyboardConnections == 1 }
    target.invalidate()
    first.send(.text("after disconnect"))
    #expect(!first.acceptsInput)
    try await waitForState { first.isClosed && second.isClosed }
    await first.close()
    await second.close()
    #expect(fixture.sources[0].stops == 1)
    #expect(fixture.keyboards[0].events.isEmpty)
    await fixture.close()
  }

  @Test
  func videoRecoveryKeepsHealthyInput() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try SharedPreviewTestSupport.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.focus(attachment)
    try await waitForState { fixture.keyboardConnections == 1 && fixture.clipboardConnections == 1 }
    fixture.sources[0].fail()
    try await waitForState { attachment.preview?.videoState == .waitingToReconnect }
    await clock.advance(by: .milliseconds(500))
    try await waitForState { fixture.sources.count == 2 && attachment.preview?.videoState == .streaming }
    attachment.send(.text("still connected"))
    try await fixture.keyboards[0].waitForEvents(1)
    #expect(fixture.keyboardConnections == 1 && fixture.clipboardConnections == 1)
    #expect(!fixture.keyboards[0].isClosed)
    await fixture.close()
  }

  @Test
  func connectRetriesPreviewAfterAConflictingRecordingEnds() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let recording = try fixture.coordinator.acquire(target: target, for: .bugReportRecording)
    let attachment = fixture.service.attach(to: target)
    attachment.setVisible(true)
    attachment.setFocused(true)
    try await waitForState { attachment.hasFailed }
    #expect(fixture.owners.isEmpty)
    fixture.coordinator.release(recording)
    attachment.retryVideo()
    try await fixture.ready(attachment)
    try await waitForState { attachment.acceptsInput }
    #expect(!attachment.hasFailed && fixture.owners.count == 1)
    await fixture.close()
  }

  @Test
  func startupHandsTheSameAttachmentToOneWindow() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try SharedPreviewTestSupport.Fixture()
    let device = fixture.device(fixture.target())
    let startup = StartupCapturePreparation(
      screenshots: { _ in preconditionFailure("Unexpected screenshot") },
      livePreview: fixture.service
    )
    startup.prepare(mode: .livePreview, devices: [device])
    try await waitForState { fixture.sources.count == 1 }
    let prepared = try #require(startup.claimLivePreview(for: device))
    #expect(startup.claimLivePreview(for: device) == nil)
    await startup.discard()
    await clock.advance(by: .seconds(6))
    #expect(!prepared.isClosed)
    #expect(fixture.owners.count == 1)
    await prepared.close()
    #expect(prepared.isClosed && fixture.sources[0].stops == 1)
    await fixture.close()
  }

  @Test
  func unusedStartupPreviewExpiresAndJoinsCleanup() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try SharedPreviewTestSupport.Fixture()
    let cleanup = TestSuspension()
    fixture.sourceCleanup = cleanup
    let device = fixture.device(fixture.target())
    let startup = StartupCapturePreparation(
      screenshots: { _ in preconditionFailure("Unexpected screenshot") },
      livePreview: fixture.service
    )
    startup.prepare(mode: .livePreview, devices: [device])
    try await waitForState { fixture.sources.count == 1 }
    await clock.advance(by: .seconds(4))
    #expect(fixture.sources[0].stops == 0)
    await clock.advance(by: .seconds(1))
    await cleanup.waitUntilStarted()
    #expect(!startup.isAvailable)
    let finished = TestValue(false)
    let entered = TestValue(false)
    let discard = Task {
      entered.value = true
      await startup.discard()
      finished.value = true
    }
    try await waitForState { entered.value }
    #expect(!finished.value)
    cleanup.resume()
    await discard.value
    startup.prepare(mode: .livePreview, devices: [device])
    #expect(startup.claimLivePreview(for: device) == nil)
    #expect(fixture.sources.count == 1 && fixture.sources[0].stops == 1)
    await fixture.close()
    try await clock.checkSuspension()
  }

  @Test
  func hiddenPaneRejectsLateViewFocusWithoutClosingSharedVideo() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let hidden = fixture.service.attach(to: target)
    let other = fixture.service.attach(to: target)
    let viewID = UUID()
    hidden.mount(viewID)
    hidden.updatePresentation(viewID: viewID, visible: true, focused: true, syncClipboard: true)
    try await waitForState { hidden.acceptsInput }
    hidden.setPaneVisible(false)
    hidden.updatePresentation(viewID: viewID, visible: true, focused: true, syncClipboard: true)
    #expect(!hidden.acceptsInput)
    #expect(!hidden.isClosed && fixture.sources[0].stops == 0)
    other.setVisible(true)
    other.setFocused(true)
    try await waitForState { other.acceptsInput }
    #expect(fixture.owners.count == 1)
    hidden.setPaneVisible(true)
    hidden.updatePresentation(viewID: viewID, visible: true, focused: true, syncClipboard: true)
    try await waitForState { hidden.acceptsInput }
    await fixture.close()
  }

  @Test
  func staleViewDisappearanceCannotDisableRemountedPreview() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    let old = UUID()
    let current = UUID()
    attachment.mount(old)
    attachment.updatePresentation(viewID: old, visible: true, focused: true, syncClipboard: true)
    try await waitForState { attachment.acceptsInput }
    attachment.mount(current)
    attachment.updatePresentation(viewID: current, visible: true, focused: true, syncClipboard: true)
    attachment.unmount(old)
    attachment.updatePresentation(viewID: old, visible: false, focused: false, syncClipboard: false)
    #expect(attachment.acceptsInput && attachment.isWindowVisible)
    attachment.unmount(current)
    #expect(!attachment.acceptsInput && !attachment.isWindowVisible)
    await fixture.close()
  }

  @Test
  func shutdownRejectsNewAttachmentsAndClosesExistingOwners() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.ready(attachment)
    await fixture.service.shutdown()
    let after = fixture.service.attach(to: fixture.target("after"))
    #expect(after.isClosed && attachment.isClosed)
    #expect(fixture.owners.count == 1 && fixture.sources[0].stops == 1)
    await fixture.close()
  }

  @Test
  func shutdownStartsOtherConnectionsCleanupWhileOneWaits() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let gate = TestSuspension()
    fixture.sourceCleanup = gate
    let first = fixture.service.attach(to: fixture.target("first"))
    try await fixture.ready(first)
    fixture.sourceCleanup = nil
    let second = fixture.service.attach(to: fixture.target("second"))
    try await fixture.ready(second)
    let finished = TestValue(false)
    let shutdown = Task { await fixture.service.shutdown()
      finished.value = true
    }
    await gate.waitUntilStarted()
    try await waitForState { fixture.sources[1].stops == 1 }
    #expect(!finished.value)
    gate.resume()
    await shutdown.value
    await fixture.close()
  }

  @Test
  func oldRendererCannotSendPointerAfterRemount() async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let target = fixture.target()
    let device = fixture.device(target)
    let attachment = fixture.service.attach(to: target)
    let oldID = UUID()
    attachment.mount(oldID)
    try await fixture.focus(attachment)
    let old = try #require(attachment.renderer(for: device, viewID: oldID))
    let newID = UUID()
    attachment.mount(newID)
    let current = try #require(attachment.renderer(for: device, viewID: newID))
    let size = CGSize(width: 100, height: 200)
    old.sendPointer(.down, .touchscreen, [CGPoint(x: 1, y: 1)], size)
    current.sendPointer(.down, .touchscreen, [CGPoint(x: 2, y: 2)], size)
    current.sendPointer(.up, .touchscreen, [CGPoint(x: 2, y: 2)], size)
    await fixture.pointers[0].waitForEvents(2)
    await fixture.close()
    let events = await fixture.pointers[0].events
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.locations == [CGPoint(x: 2, y: 2)] })
  }
}

import Clocks
import DependenciesTestSupport
import Foundation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct LivePreviewAttachmentTests {
  @Test
  func hidingAndRemountingRestartsVideoOnTheSameOwner() async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    let firstView = UUID()
    attachment.mount(firstView)
    attachment.updatePresentation(viewID: firstView, visible: true, focused: true, syncClipboard: false)
    try await fixture.ready(attachment)
    attachment.updatePresentation(viewID: firstView, visible: false, focused: false, syncClipboard: false)
    let nextView = UUID()
    attachment.mount(nextView)
    attachment.updatePresentation(viewID: nextView, visible: true, focused: true, syncClipboard: false)
    attachment.unmount(firstView)
    try await fixture.ready(attachment)
    #expect(fixture.sources.count == 2 && fixture.sources[0].stops == 1)
    #expect(fixture.owners.count == 1)
    #expect(attachment.isWindowVisible)
    attachment.unmount(nextView)
    #expect(!attachment.isWindowVisible && !attachment.isClosed)
    await attachment.close()
    #expect(fixture.sources[0].stops == 1)
    await fixture.close()
  }

  @Test
  func hidingDuringPreparationKeepsTheSameOwner() async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    let gate = TestSuspension()
    fixture.preparationGate = gate
    let attachment = fixture.service.attach(to: fixture.target())
    attachment.setVisible(true)
    await gate.waitUntilStarted()
    attachment.setVisible(false)
    gate.resume()
    try await waitForState { attachment.preview?.inputReady == true }
    #expect(attachment.preview?.videoState == .idle)
    attachment.setVisible(true)
    try await fixture.ready(attachment)
    #expect(fixture.owners.count == 1)
    #expect(!attachment.acceptsInput)
    await fixture.close()
  }

  @Test
  func failedVideoIsNotRetriedByRemountingAView() async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    fixture.videoStartupError = CocoaError(.fileReadUnknown)
    let attachment = fixture.service.attach(to: fixture.target())
    try await waitForState { attachment.hasFailed }
    let old = UUID()
    attachment.mount(old)
    attachment.unmount(old)
    attachment.mount(UUID())
    #expect(attachment.hasFailed)
    #expect(fixture.owners.count == 1)
    await fixture.close()
  }

  @Test
  func repeatedCloseJoinsCleanupAndRejectsLaterMounts() async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    let gate = TestSuspension()
    fixture.sourceCleanup = gate
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.ready(attachment)
    let finished = TestValue(0)
    let first = Task { await attachment.close(); finished.value += 1 }
    await gate.waitUntilStarted()
    let entered = TestValue(false)
    let second = Task {
      entered.value = true
      await attachment.close()
      finished.value += 1
    }
    try await waitForState { entered.value }
    let view = UUID()
    attachment.mount(view)
    attachment.updatePresentation(viewID: view, visible: true, focused: true, syncClipboard: true)
    attachment.retryVideo()
    #expect(attachment.isClosed && !attachment.acceptsInput)
    #expect(finished.value == 0 && fixture.sources.count == 1)
    gate.resume()
    await first.value
    await second.value
    #expect(finished.value == 2 && fixture.sources[0].stops == 1)
    await fixture.close()
  }
}

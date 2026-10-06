import AppKit
import Testing

@MainActor
@Suite(.serialized)
struct WindowVisibilityTests {
  @Test
  func windowChangesReachTheCurrentCallback() async {
    let window = makeWindow()
    var first: [Bool] = []
    var current: [Bool] = []
    let view = WindowVisibilityView { first.append($0) }
    window.contentView?.addSubview(view)
    await view.pendingReport?.value
    #expect(first == [true])
    view.visibilityDidChange = { current.append($0) }
    window.testOcclusion = []
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await view.pendingReport?.value
    #expect(current == [false])
    window.testOcclusion = .visible
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await view.pendingReport?.value
    #expect(current == [false, true])
    view.stopObserving()
    window.close()
  }

  @Test
  func focusChangeRechecksVisibilityWithoutHidingAnUnfocusedWindow() async {
    let window = makeWindow()
    var changes: [Bool] = []
    let view = WindowVisibilityView { changes.append($0) }
    window.contentView?.addSubview(view)
    await view.pendingReport?.value
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    await view.pendingReport?.value
    #expect(changes == [true])
    window.testOcclusion = []
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    await view.pendingReport?.value
    #expect(changes == [true, false])
    view.stopObserving()
    window.close()
  }

  @Test
  func reattachmentRejectsTheOldWindowsPendingReport() async {
    let first = makeWindow()
    let second = makeWindow()
    second.testOcclusion = []
    var changes: [Bool] = []
    let view = WindowVisibilityView { changes.append($0) }
    first.contentView?.addSubview(view)
    let oldReport = view.pendingReport
    second.contentView?.addSubview(view)
    await oldReport?.value
    await view.pendingReport?.value
    #expect(changes == [false])
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: first)
    second.testOcclusion = .visible
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: second)
    await view.pendingReport?.value
    #expect(changes == [false, true])
    view.stopObserving()
    first.close()
    second.close()
  }

  @Test
  func dismantleCancelsPendingVisibilityDelivery() async {
    let window = makeWindow()
    var changes: [Bool] = []
    let view = WindowVisibilityView { changes.append($0) }
    window.contentView?.addSubview(view)
    let pending = view.pendingReport
    view.stopObserving()
    await pending?.value
    #expect(changes.isEmpty)
    window.close()
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SNAPO_TEST_WINDOWS"] == "1"), .timeLimit(.minutes(1)))
  func coveringAndUncoveringARealWindowUpdatesVisibility() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 240, height: 160), styleMask: [.titled], backing: .buffered, defer: false
    )
    let cover = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    cover.isReleasedWhenClosed = false
    window.title = "Snap-O visibility check"
    window.level = .floating
    cover.level = .floating
    cover.isOpaque = true
    cover.backgroundColor = .windowBackgroundColor
    cover.setFrame(window.frame.insetBy(dx: -20, dy: -20), display: false)
    let changes = AsyncStream<Bool>.makeStream()
    let view = WindowVisibilityView { changes.continuation.yield($0) }
    window.contentView?.addSubview(view)
    defer {
      view.stopObserving()
      changes.continuation.finish()
      cover.close()
      window.close()
    }
    var iterator = changes.stream.makeAsyncIterator()
    window.orderFrontRegardless()
    try await nextVisibility(true, from: &iterator)
    cover.orderFrontRegardless()
    try await nextVisibility(false, from: &iterator)
    cover.orderOut(nil)
    try await nextVisibility(true, from: &iterator)
    window.orderOut(nil)
    try await nextVisibility(false, from: &iterator)
  }

  private func nextVisibility(_ expected: Bool, from iterator: inout AsyncStream<Bool>.Iterator) async throws {
    while let visible = await iterator.next(isolation: MainActor.shared) {
      if visible == expected { return }
    }
    Issue.record("Visibility stream ended before the expected change")
    throw CancellationError()
  }

  private func makeWindow() -> VisibilityTestWindow {
    _ = NSApplication.shared
    let window = VisibilityTestWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }
}

@MainActor
private final class VisibilityTestWindow: NSWindow {
  var testOcclusion: NSWindow.OcclusionState = .visible
  override var occlusionState: NSWindow.OcclusionState { testOcclusion }
  override var isVisible: Bool { true }
  override var isMiniaturized: Bool { false }
}

import AppKit
@testable import Snap_O
import Testing

@MainActor
struct WindowSizingTests {
  @Test(arguments: [true, false])
  func fullScreenWaitsForAnOrderedKeyWindowToBecomeVisible(uncovered: Bool) async throws {
    let suite = "WindowSizingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sizing = WindowSizingController.Coordinator(defaults: defaults)
    let window = FullScreenVisibilityWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    var completions: [Bool] = []
    sizing.fullScreen.onChange = { event in
      if case .didChange(let visible) = event { completions.append(visible) }
    }
    sizing.attach(to: window)
    sizing.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
    sizing.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
    await sizing.fullScreen.visibilityReport?.value
    #expect(completions.isEmpty)

    if uncovered {
      window.reportedOcclusion = .visible
      sizing.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window))
    } else {
      window.reportedKey = false
      sizing.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    }
    await sizing.fullScreen.visibilityReport?.value
    #expect(completions == [uncovered])
  }

  @Test(arguments: [true, false], [true, false])
  func fullScreenHandoffsReportVisibilityAfterSuccessOrFailure(entering: Bool, failed: Bool) async throws {
    let suite = "WindowSizingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sizing = WindowSizingController.Coordinator(defaults: defaults)
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    var completions: [Bool] = []
    var began = 0
    sizing.fullScreen.onChange = { event in
      switch event {
      case .willChange: began += 1
      case .didChange(let visible): completions.append(visible)
      }
    }
    sizing.attach(to: window)
    if entering {
      sizing.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
      if failed { sizing.windowDidFailToEnterFullScreen(window) } else {
        sizing.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
      }
    } else {
      sizing.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
      if failed { sizing.windowDidFailToExitFullScreen(window) } else {
        sizing.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
      }
    }
    await sizing.fullScreen.visibilityReport?.value
    #expect(began == 1)
    #expect(completions == [window.isVisibleForPlayback])
  }

  @Test(arguments: [WorkspaceWindowEdge.left, .right, .top, .bottom])
  func doubleClickingAnEdgeFitsTheWindowToItsDesktop(_ edge: WorkspaceWindowEdge) async throws {
    let suite = "WindowSizingTests.\(UUID().uuidString)"
    let defaults = try #require(WindowFrameDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let desktop = try #require(NSScreen.main).visibleFrame
    let preview = edge == .top || edge == .bottom ? CGSize(width: 780, height: 260) : CGSize(width: 300, height: 600)
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: desktop.midX - preview.width / 2, y: desktop.midY - preview.height / 2), size: preview),
      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false
    )
    let sizing = WindowSizingController.Coordinator(defaults: defaults)
    sizing.update(
      layout: .capture, displayInfo: DisplayInfo(size: preview, densityScale: 1),
      capturePaneWidth: preview.width, capturePaneWidthChanged: { _ in }, presentationChanged: { _ in }
    )
    sizing.attach(to: window)
    sizing.startMonitoringEdgeClicks()
    defer { sizing.stopMonitoringEdgeClicks() }

    let initial = window.frame
    let point = switch edge {
    case .left: CGPoint(x: 0, y: initial.height / 2)
    case .right: CGPoint(x: initial.width, y: initial.height / 2)
    case .top: CGPoint(x: initial.width / 2, y: initial.height)
    case .bottom: CGPoint(x: initial.width / 2, y: 0)
    }
    func click(count: Int) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: point,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: count, pressure: 1
      ))
    }

    let chrome = WindowChromeMetrics.totalToolbarHeight
    let aspect = preview.width / preview.height
    let width = min(desktop.width, (desktop.height - chrome) * aspect)
    let size = CGSize(width: width, height: width / aspect + chrome)
    #expect(try !sizing.fitWindowOnEdgeDoubleClick(click(count: 1)))
    let revision = defaults.frameSaved.revision
    let doubleClick = try click(count: 2)
    NSApp.sendEvent(doubleClick)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      #expect(defaults.frameSaved.revision == revision)
    }
    try await defaults.frameSaved.wait(after: revision)

    let frame = window.frame
    let anchored = edge.resizeAnchor.frame(with: size, relativeTo: initial)
    let expectedX = min(max(anchored.minX, desktop.minX), desktop.maxX - size.width)
    let expectedY = min(max(anchored.minY, desktop.minY), desktop.maxY - size.height)
    #expect(abs(frame.minX - expectedX) <= 1)
    #expect(abs(frame.minY - expectedY) <= 1)
    #expect(abs(frame.width - size.width) <= 1)
    #expect(abs(frame.height - size.height) <= 1)
    #expect(desktop.insetBy(dx: -1, dy: -1).contains(frame))
    #expect(defaults.string(forKey: "workspace.windowFrame.capture") == NSStringFromRect(frame))

    sizing.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
    #expect(!sizing.fitWindowOnEdgeDoubleClick(doubleClick))
  }

  @Test
  func togglingTheToolDuringAnEdgeFitAnimatesFromTheFittedFrameToTheReportedDestination() async throws {
    let suite = "WindowSizingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sizing = WindowSizingController.Coordinator(defaults: defaults)
    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 300, height: 600),
      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false
    )
    let display = DisplayInfo(size: CGSize(width: 300, height: 600), densityScale: 1)
    var captureWidth: CGFloat = 300
    sizing.update(
      layout: .capture, displayInfo: display, capturePaneWidth: captureWidth,
      capturePaneWidthChanged: { captureWidth = $0 }, presentationChanged: { _ in }
    )
    sizing.attach(to: window)

    let desktop = try #require(window.screen).visibleFrame
    let fittedWidth = min(desktop.width, (desktop.height - WindowChromeMetrics.totalToolbarHeight) * display.aspectRatio)
    let doubleClick = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown, location: CGPoint(x: window.frame.width, y: window.frame.height / 2),
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
    ))
    #expect(sizing.fitWindowOnEdgeDoubleClick(doubleClick))

    for layout in [WorkspaceLayout.both, .capture] {
      var announced: WorkspaceLayoutTransition?
      let completed = TestSignal()
      let revision = completed.revision
      sizing.update(
        layout: layout, displayInfo: display, capturePaneWidth: captureWidth,
        capturePaneWidthChanged: { captureWidth = $0 },
        presentationChanged: { event in
          switch event {
          case .transitionWillBegin(let transition): announced = transition
          case .layoutDidApply(let applied) where applied == layout: completed.signal()
          case .layoutDidApply: break
          }
        }
      )
      try await completed.wait(after: revision)
      let transition = try #require(announced)
      if layout == .both { #expect(abs(transition.initialWindowWidth - fittedWidth) <= 1) }
      #expect(abs(window.frame.width - transition.finalWindowWidth) <= 1)
      #expect(defaults.string(forKey: "workspace.windowFrame.\(layout.rawValue)") == NSStringFromRect(window.frame))
    }
  }

  @Test
  func splitViewKeepsItsFrameWhenResizedOrRotated() async throws {
    let suite = "WindowSizingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sizing = WindowSizingController.Coordinator(defaults: defaults)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 640),
      styleMask: [.borderless, .resizable], backing: .buffered, defer: false
    )
    let portrait = DisplayInfo(size: CGSize(width: 320, height: 640), densityScale: 1)
    let landscape = DisplayInfo(size: CGSize(width: 640, height: 320), densityScale: 1)
    func update(
      _ layout: WorkspaceLayout, display: DisplayInfo,
      presented: @escaping @MainActor (WorkspaceLayoutPresentationEvent) -> Void = { _ in }
    ) {
      sizing.update(
        layout: layout, displayInfo: display, capturePaneWidth: 320,
        capturePaneWidthChanged: { _ in }, presentationChanged: presented
      )
    }

    update(.capture, display: portrait)
    sizing.attach(to: window)
    #expect(window.minFullScreenContentSize.height == WindowChromeMetrics.totalToolbarHeight + WorkspaceLayout.minimumCaptureEdge)
    let windowedFrame = window.frame
    let move = Notification(name: NSWindow.didMoveNotification, object: window)
    sizing.windowDidMove(move)
    let savedFrame = try #require(defaults.string(forKey: "workspace.windowFrame.capture"))

    sizing.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
    let screen = CGSize(width: 1440, height: 900)
    #expect(sizing.windowWillResize(window, to: screen) == screen)
    sizing.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
    for width: CGFloat in [400, 720, 1100] {
      let tile = CGSize(width: width, height: screen.height)
      #expect(sizing.windowWillResize(window, to: tile) == tile)
      window.setFrame(CGRect(origin: windowedFrame.origin, size: tile), display: false)
      sizing.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
      sizing.windowDidMove(move)
    }

    let tileFrame = window.frame
    update(.capture, display: landscape)
    #expect(window.frame == tileFrame)
    for layout in [WorkspaceLayout.both, .capture] {
      await withCheckedContinuation { continuation in
        update(layout, display: landscape) { event in
          if case .layoutDidApply(layout) = event { continuation.resume() }
        }
      }
      #expect(window.frame == tileFrame)
    }
    #expect(defaults.string(forKey: "workspace.windowFrame.capture") == savedFrame)

    let willExit = Notification(name: NSWindow.willExitFullScreenNotification, object: window)
    sizing.windowWillExitFullScreen(willExit)
    sizing.window(window, startCustomAnimationToExitFullScreenWithDuration: 0)
    #expect(window.frame == windowedFrame)
    sizing.windowDidFailToExitFullScreen(window)
    #expect(window.frame == tileFrame)

    sizing.windowWillExitFullScreen(willExit)
    sizing.window(window, startCustomAnimationToExitFullScreenWithDuration: 0)
    sizing.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    let proposed = CGSize(width: 600, height: 900)
    #expect(sizing.windowWillResize(window, to: proposed) == CGSize(
      width: 600, height: (WindowChromeMetrics.totalToolbarHeight + 300).rounded()
    ))
  }
}

private final class WindowFrameDefaults: UserDefaults {
  let frameSaved = TestSignal()

  override func set(_ value: Any?, forKey defaultName: String) {
    super.set(value, forKey: defaultName)
    if defaultName == "workspace.windowFrame.capture" { frameSaved.signal() }
  }
}

private final class FullScreenVisibilityWindow: NSWindow {
  var reportedKey = true
  var reportedOcclusion: NSWindow.OcclusionState = []
  override var isVisible: Bool {
    true
  }

  override var isKeyWindow: Bool {
    reportedKey
  }

  override var occlusionState: NSWindow.OcclusionState {
    reportedOcclusion
  }
}

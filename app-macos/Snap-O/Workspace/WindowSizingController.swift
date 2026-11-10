import AppKit
import SwiftUI

/// Owns the main workspace window's aspect constraint and frame persistence.
/// Layout transitions preserve pane sizes while the window absorbs the added
/// or removed pane.
struct WindowSizingController: NSViewRepresentable {
  let displayInfo: DisplayInfo?
  let layout: WorkspaceLayout
  let capturePaneWidth: CGFloat
  let capturePaneWidthChanged: @MainActor (CGFloat) -> Void
  let presentationChanged: @MainActor (WorkspaceLayoutPresentationEvent) -> Void
  let fullScreenChanged: @MainActor (WindowFullScreenController.Event) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let coordinator = context.coordinator
    coordinator.startMonitoringEdgeClicks()
    updateNSView(view, context: context)
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      coordinator.attach(to: window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.fullScreen.onChange = fullScreenChanged
    context.coordinator.update(
      layout: layout,
      displayInfo: displayInfo,
      capturePaneWidth: capturePaneWidth,
      capturePaneWidthChanged: capturePaneWidthChanged,
      presentationChanged: presentationChanged
    )
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stopMonitoringEdgeClicks()
  }

  @MainActor
  final class Coordinator: NSObject, NSWindowDelegate {
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
      CaptureSheetAnchor.attachmentRect(in: window, sheet: sheet) ?? rect
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      CaptureReviewCloseGuard.prepareToClose(in: sender)
    }

    private enum Constants {
      static let toolContentSize = CGSize(width: 1100, height: 720)
      static let bothContentSize = CGSize(width: 1300, height: 760)
      static let defaultToolPaneWidth: CGFloat = 940
    }

    private weak var window: NSWindow?
    private let edgeFit = WindowEdgeFitController()
    private let defaults: UserDefaults
    private var currentAspect: CGFloat = 1
    private var currentLayout: WorkspaceLayout?
    private var currentDisplayInfo: DisplayInfo?
    private var currentCapturePaneWidth = WorkspaceLayoutController.defaultCapturePaneWidth
    private var rememberedToolPaneWidth = Constants.defaultToolPaneWidth
    private var pendingLayout: WorkspaceLayout = .capture
    private var pendingDisplayInfo: DisplayInfo?
    private var pendingCapturePaneWidth = WorkspaceLayoutController.defaultCapturePaneWidth
    private var capturePaneWidthChanged: (@MainActor (CGFloat) -> Void)?
    private var presentationChanged: @MainActor (WorkspaceLayoutPresentationEvent) -> Void = { _ in }
    private var transitionGeneration = 0
    private var isApplyingLayoutTransition = false
    let fullScreen = WindowFullScreenController()

    init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
    }

    func attach(to window: NSWindow) {
      guard self.window !== window else { return }
      self.window = window
      fullScreen.attach(to: window)
      CommandDiagnostics.shared.replacingDelegate(of: window, with: self)
      window.delegate = self
      applyPendingUpdate()
    }

    func startMonitoringEdgeClicks() {
      edgeFit.startMonitoring { [weak self] event in self?.fitWindowOnEdgeDoubleClick(event) ?? false }
    }

    func stopMonitoringEdgeClicks() {
      edgeFit.stopMonitoring()
    }

    func fitWindowOnEdgeDoubleClick(_ event: NSEvent) -> Bool {
      guard let window, let layout = currentLayout, !fullScreen.usesFullScreenFrame, !isApplyingLayoutTransition else { return false }
      return edgeFit.fit(
        on: event, in: window, layout: layout, captureAspectRatio: currentDisplayInfo?.aspectRatio ?? currentAspect
      ) { [weak self, weak window] in
        guard let self else { return }
        if let window, self.window === window, !fullScreen.usesFullScreenFrame, currentLayout == layout {
          rememberWindowSize(window, layout: layout)
        }
        applyPendingUpdate()
      }
    }

    func update(
      layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      capturePaneWidth: CGFloat,
      capturePaneWidthChanged: @escaping @MainActor (CGFloat) -> Void,
      presentationChanged: @escaping @MainActor (WorkspaceLayoutPresentationEvent) -> Void
    ) {
      let pendingLayoutChanged = pendingLayout != layout
      pendingLayout = layout
      pendingDisplayInfo = displayInfo
      pendingCapturePaneWidth = capturePaneWidth
      self.capturePaneWidthChanged = capturePaneWidthChanged
      self.presentationChanged = presentationChanged
      applyPendingUpdate(pendingLayoutChanged: pendingLayoutChanged)
    }

    private func applyPendingUpdate(pendingLayoutChanged: Bool = false) {
      guard let window else { return }
      let layout = pendingLayout
      let displayInfo = pendingDisplayInfo

      if fullScreen.usesFullScreenFrame {
        if pendingLayoutChanged || isApplyingLayoutTransition {
          transitionGeneration += 1
          let generation = transitionGeneration
          isApplyingLayoutTransition = false
          DispatchQueue.main.async { [weak self, presentationChanged] in
            guard self?.transitionGeneration == generation else { return }
            presentationChanged(.layoutDidApply(layout))
          }
        }
        return
      }
      // Start any pending pane or device resize from the settled window frame.
      guard !edgeFit.isAnimating else { return }

      let previousLayout = currentLayout
      let layoutChanged = previousLayout != nil && previousLayout != layout
      let displayChanged = currentDisplayInfo != displayInfo
      currentCapturePaneWidth = pendingCapturePaneWidth

      if isApplyingLayoutTransition, !layoutChanged {
        return
      }

      if currentLayout == nil {
        currentLayout = layout
        currentDisplayInfo = displayInfo
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
        applyInitialFrame(for: layout, displayInfo: displayInfo, to: window)
        ensureMinimumBothContentSize(displayInfo: displayInfo, window: window)
        synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      } else if layoutChanged, let previousLayout {
        changeLayout(from: previousLayout, to: layout, displayInfo: displayInfo, in: window)
        return
      } else if layout == .capture, displayChanged, let displayInfo {
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
        sizeCaptureWindow(for: displayInfo, window: window, anchor: .top)
        synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      } else {
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
        ensureMinimumBothContentSize(displayInfo: displayInfo, window: window)
      }

      currentDisplayInfo = displayInfo
    }

    private func changeLayout(
      from previousLayout: WorkspaceLayout,
      to layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      in window: NSWindow
    ) {
      let frame = window.frame
      rememberPaneSizes(for: previousLayout, window: window)
      saveFrame(frame, layout: previousLayout)
      let previousAspectRatio = currentDisplayInfo?.aspectRatio
      currentLayout = layout
      currentDisplayInfo = displayInfo
      if layout == .capture, let displayInfo { updateAspect(for: displayInfo) }
      let contentMinimum = WindowChromeMetrics.sizeIncludingToolbar(layout.minimumContentSize(captureAspectRatio: displayInfo?.aspectRatio))
      let snapshot = WorkspaceLayoutChange.Snapshot(
        frame: frame, desktopFrame: (window.screen ?? NSScreen.main)?.visibleFrame,
        chromeHeight: WindowChromeMetrics.totalToolbarHeight,
        minimumFrameSize: window.frameRect(forContentRect: CGRect(origin: .zero, size: contentMinimum)).size,
        rememberedPanes: WorkspacePaneWidths(capture: currentCapturePaneWidth, tool: rememberedToolPaneWidth),
        previousDisplayAspectRatio: previousAspectRatio, windowedCaptureAspectRatio: currentAspect
      )
      let change = WorkspaceLayoutChange(from: previousLayout, to: layout, snapshot: snapshot, displayAspectRatio: displayInfo?.aspectRatio)
      transitionGeneration += 1
      let generation = transitionGeneration
      isApplyingLayoutTransition = true

      DispatchQueue.main.async { [weak self, weak window, presentationChanged] in
        guard let self, let window, transitionGeneration == generation, currentLayout == layout else { return }
        if let transition = change.paneTransition {
          presentationChanged(.transitionWillBegin(transition))
        } else {
          presentationChanged(.layoutDidApply(layout))
        }
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)

        // Let SwiftUI mount the panes before AppKit starts resizing the window.
        DispatchQueue.main.async { [weak self, weak window] in
          guard let self, let window, transitionGeneration == generation, currentLayout == layout else { return }
          if let width = change.captureWidthToRemember { synchronizeCapturePaneWidth(width) }
          if let width = change.toolWidthToRemember { rememberedToolPaneWidth = width }
          window.animateWorkspaceFrame(to: change.targetFrame) { [weak self, weak window] in
            guard let self, let window, transitionGeneration == generation, currentLayout == layout else { return }
            presentationChanged(.layoutDidApply(layout))
            isApplyingLayoutTransition = false
            rememberPaneSizes(for: layout, window: window)
            saveFrame(window.frame, layout: layout)
            applyPendingUpdate()
          }
        }
      }
    }

    /// Animates the live window so the preview fits each intermediate frame.
    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
      [window]
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen, withDuration duration: TimeInterval) {
      fullScreen.animateEntry(window, on: screen, duration: duration)
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
      fullScreen.windowsForExit(window)
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
      fullScreen.animateExit(window, duration: duration)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
      fullScreen.willEnter()
      applyPendingUpdate()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
      fullScreen.didEnter()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
      fullScreen.willExit()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
      fullScreen.didExit()
      resumeWindowedSizing()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
      fullScreen.failedToEnter(window)
      resumeWindowedSizing()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
      fullScreen.failedToExit(window)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
      fullScreen.reportVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
      fullScreen.reportVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
      fullScreen.reportVisibility()
    }

    private func resumeWindowedSizing() {
      // Restore the windowed frame for the layout the user selected in full screen.
      if currentLayout != pendingLayout { currentLayout = nil }
      applyPendingUpdate()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
      guard !fullScreen.usesFullScreenFrame else { return frameSize }
      let width = max(frameSize.width, sender.minSize.width)
      guard currentLayout == .capture, !isApplyingLayoutTransition else {
        return NSSize(width: width, height: frameSize.height)
      }
      let aspect = max(currentAspect, 0.0001)
      return NSSize(
        width: width,
        height: (WindowChromeMetrics.totalToolbarHeight + (width / aspect)).rounded()
      )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
      guard !fullScreen.usesFullScreenFrame, !edgeFit.isAnimating, let window = notification.object as? NSWindow,
            let currentLayout else { return }
      rememberWindowSize(window, layout: currentLayout)
    }

    func windowDidMove(_ notification: Notification) {
      guard !fullScreen.usesFullScreenFrame, !edgeFit.isAnimating else { return }
      saveCurrentFrame(from: notification)
    }

    private func applyInitialFrame(
      for layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      to window: NSWindow
    ) {
      if let storedFrame = storedFrame(layout: layout) {
        window.setFrame(constrained(storedFrame, for: window), display: true, animate: false)
        if layout == .capture, let displayInfo {
          updateAspect(for: displayInfo)
          reshapeCaptureWindow(window, anchor: .top)
        }
        rememberPaneSizes(for: layout, window: window)
        return
      }

      switch layout {
      case .capture:
        if let displayInfo {
          sizeCaptureWindow(for: displayInfo, window: window, anchor: .top)
        }
      case .tool:
        setContentSize(Constants.toolContentSize, for: window, anchor: .top)
      case .both:
        setContentSize(Constants.bothContentSize, for: window, anchor: .top)
      }
      rememberPaneSizes(for: layout, window: window)
    }

    private func applyMinimumSize(
      layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      to window: NSWindow
    ) {
      window.contentMinSize = WindowChromeMetrics
        .sizeIncludingToolbar(layout.minimumContentSize(captureAspectRatio: displayInfo?.aspectRatio))
      // Split View can fit the preview inside a tile of any aspect ratio.
      window.minFullScreenContentSize = WindowChromeMetrics.sizeIncludingToolbar(layout.minimumContentSize(captureAspectRatio: nil))
    }

    private func ensureMinimumBothContentSize(
      displayInfo: DisplayInfo?,
      window: NSWindow
    ) {
      guard currentLayout == .both else { return }
      let minimumSize = WorkspaceLayout.both.minimumContentSize(captureAspectRatio: displayInfo?.aspectRatio)
      let currentSize = WindowChromeMetrics.workspaceSize(in: window.frame)
      let targetSize = CGSize(
        width: max(currentSize.width, minimumSize.width),
        height: max(currentSize.height, minimumSize.height)
      )
      guard targetSize != currentSize else { return }
      setContentSize(targetSize, for: window, anchor: .topLeft)
    }

    private func sizeCaptureWindow(
      for displayInfo: DisplayInfo,
      window: NSWindow,
      anchor: WorkspaceWindowAnchor
    ) {
      let targetContentSize = scaledContentSize(for: displayInfo)
      updateAspect(for: displayInfo)
      setContentSize(targetContentSize, for: window, anchor: anchor)
    }

    private func reshapeCaptureWindow(_ window: NSWindow, anchor: WorkspaceWindowAnchor) {
      let contentWidth = window.frame.width
      let contentSize = CGSize(width: contentWidth, height: contentWidth / max(currentAspect, 0.0001))
      setContentSize(contentSize, for: window, anchor: anchor)
    }

    private func updateAspect(for displayInfo: DisplayInfo) {
      let contentSize = scaledContentSize(for: displayInfo)
      currentAspect = contentSize.width / max(contentSize.height, 1)
    }

    private func setContentSize(_ contentSize: CGSize, for window: NSWindow, anchor: WorkspaceWindowAnchor) {
      let frame = anchor.frame(with: WindowChromeMetrics.sizeIncludingToolbar(contentSize), relativeTo: window.frame)
      window.setFrame(constrained(frame, for: window), display: true, animate: false)
    }

    private func scaledContentSize(for display: DisplayInfo) -> CGSize {
      var width = display.size.width
      if let density = display.densityScale, density > 0 {
        width /= density
      }
      let minimum = WorkspaceLayout.capture.minimumContentSize(captureAspectRatio: display.aspectRatio)
      width = max(width.rounded(), minimum.width)
      return CGSize(width: width.rounded(), height: (width / display.aspectRatio).rounded())
    }

    private func rememberWindowSize(_ window: NSWindow, layout: WorkspaceLayout) {
      rememberPaneSizes(for: layout, window: window)
      synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      saveFrame(window.frame, layout: layout)
    }

    private func rememberPaneSizes(for layout: WorkspaceLayout, window: NSWindow) {
      let contentWidth = window.frame.width
      switch layout {
      case .capture:
        currentCapturePaneWidth = contentWidth
      case .tool, .both:
        let panes = WorkspacePanePresentation(
          layout: layout, windowWidth: contentWidth, preferredCaptureWidth: currentCapturePaneWidth,
          captureAspectRatio: currentDisplayInfo?.aspectRatio
        )
        rememberedToolPaneWidth = max(panes.toolWidth, WorkspaceLayout.minimumToolSize.width)
      }
    }

    private func synchronizeCapturePaneWidthIfNeeded(
      for layout: WorkspaceLayout?,
      window: NSWindow
    ) {
      guard layout == .capture else { return }
      synchronizeCapturePaneWidth(window.frame.width)
    }

    private func synchronizeCapturePaneWidth(_ width: CGFloat) {
      let width = max(
        width.rounded(),
        WorkspaceLayout.minimumCapturePaneWidth(aspectRatio: currentDisplayInfo?.aspectRatio)
      )
      currentCapturePaneWidth = width
      guard abs(pendingCapturePaneWidth - width) > 0.5 else { return }
      pendingCapturePaneWidth = width
      guard let capturePaneWidthChanged else { return }
      DispatchQueue.main.async {
        capturePaneWidthChanged(width)
      }
    }

    private func constrained(_ frame: NSRect, for window: NSWindow) -> NSRect {
      WorkspaceLayout.constrainedWindowFrame(frame, to: (window.screen ?? NSScreen.main)?.visibleFrame, minimumWidth: window.minSize.width)
    }

    private func saveCurrentFrame(from notification: Notification) {
      guard let window = notification.object as? NSWindow, let currentLayout else { return }
      saveFrame(window.frame, layout: currentLayout)
    }

    private func saveFrame(_ frame: NSRect, layout: WorkspaceLayout) {
      defaults.set(NSStringFromRect(frame), forKey: frameKey(layout))
    }

    private func storedFrame(layout: WorkspaceLayout) -> NSRect? {
      guard let value = defaults.string(forKey: frameKey(layout)) else { return nil }
      let frame = NSRectFromString(value)
      return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private func frameKey(_ layout: WorkspaceLayout) -> String {
      "workspace.windowFrame.\(layout.rawValue)"
    }
  }
}

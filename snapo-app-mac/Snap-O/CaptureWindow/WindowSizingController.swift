import AppKit
import SwiftUI

/// Owns the main workspace window's aspect constraint and frame persistence.
/// Layout transitions preserve pane sizes while the window absorbs the added
/// or removed pane. Capture visibility changes keep the window's left edge fixed.
struct WindowSizingController: NSViewRepresentable {
  let displayInfo: DisplayInfo?
  let layout: WorkspaceLayout
  let capturePaneWidth: CGFloat
  let capturePaneWidthChanged: @MainActor (CGFloat) -> Void
  let layoutWillApply: @MainActor (WorkspaceLayout) -> Void

  private static let minimumCaptureEdge: CGFloat = 240

  func makeCoordinator() -> Coordinator {
    Coordinator(minimumCaptureEdge: Self.minimumCaptureEdge)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      context.coordinator.attach(to: window)
      context.coordinator.update(
        layout: layout,
        displayInfo: displayInfo,
        capturePaneWidth: capturePaneWidth,
        capturePaneWidthChanged: capturePaneWidthChanged,
        layoutWillApply: layoutWillApply
      )
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(
      layout: layout,
      displayInfo: displayInfo,
      capturePaneWidth: capturePaneWidth,
      capturePaneWidthChanged: capturePaneWidthChanged,
      layoutWillApply: layoutWillApply
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSWindowDelegate {
    private struct LayoutSnapshot {
      let frame: NSRect
      let workspaceSize: CGSize
    }

    private enum Constants {
      static let networkContentSize = CGSize(width: 1100, height: 720)
      static let bothContentSize = CGSize(width: 1300, height: 760)
      static let minimumNetworkContentSize = CGSize(width: 720, height: 480)
      static let minimumBothContentSize = CGSize(width: 980, height: 480)
      static let defaultNetworkPaneWidth: CGFloat = 940
      static let dividerWidth: CGFloat = 1
    }

    private enum HorizontalAnchor {
      case leading
      case center
      case trailing
    }

    private weak var window: NSWindow?
    private let minimumCaptureEdge: CGFloat
    private var currentAspect: CGFloat = 1
    private var currentLayout: WorkspaceLayout?
    private var currentDisplayInfo: DisplayInfo?
    private var currentCapturePaneWidth = WorkspaceLayoutController.defaultCapturePaneWidth
    private var rememberedNetworkPaneWidth = Constants.defaultNetworkPaneWidth
    private var pendingLayout: WorkspaceLayout = .capture
    private var pendingDisplayInfo: DisplayInfo?
    private var pendingCapturePaneWidth = WorkspaceLayoutController.defaultCapturePaneWidth
    private var capturePaneWidthChanged: (@MainActor (CGFloat) -> Void)?
    private var layoutWillApply: (@MainActor (WorkspaceLayout) -> Void)?
    private var transitionGeneration = 0
    private var isApplyingLayoutTransition = false

    init(minimumCaptureEdge: CGFloat) {
      self.minimumCaptureEdge = minimumCaptureEdge
    }

    func attach(to window: NSWindow) {
      guard self.window !== window else { return }
      self.window = window
      window.delegate = self
      update(
        layout: pendingLayout,
        displayInfo: pendingDisplayInfo,
        capturePaneWidth: pendingCapturePaneWidth,
        capturePaneWidthChanged: capturePaneWidthChanged ?? { _ in },
        layoutWillApply: layoutWillApply ?? { _ in }
      )
    }

    func update(
      layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      capturePaneWidth: CGFloat,
      capturePaneWidthChanged: @escaping @MainActor (CGFloat) -> Void,
      layoutWillApply: @escaping @MainActor (WorkspaceLayout) -> Void
    ) {
      pendingLayout = layout
      pendingDisplayInfo = displayInfo
      pendingCapturePaneWidth = capturePaneWidth
      self.capturePaneWidthChanged = capturePaneWidthChanged
      self.layoutWillApply = layoutWillApply
      guard let window else { return }

      let previousLayout = currentLayout
      let layoutChanged = previousLayout != nil && previousLayout != layout
      let displayChanged = currentDisplayInfo != displayInfo
      currentCapturePaneWidth = capturePaneWidth

      if isApplyingLayoutTransition, !layoutChanged {
        currentDisplayInfo = displayInfo
        return
      }

      if currentLayout == nil {
        currentLayout = layout
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
        applyInitialFrame(for: layout, displayInfo: displayInfo, to: window)
        synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      } else if layoutChanged, let previousLayout {
        let snapshot = LayoutSnapshot(
          frame: window.frame,
          workspaceSize: workspaceContentSize(for: window)
        )
        rememberPaneSizes(for: previousLayout, window: window)
        saveFrame(snapshot.frame, layout: previousLayout)

        currentLayout = layout
        currentDisplayInfo = displayInfo
        transitionGeneration += 1
        let generation = transitionGeneration
        isApplyingLayoutTransition = true

        DispatchQueue.main.async { [weak self, weak window] in
          guard
            let self,
            let window,
            transitionGeneration == generation,
            currentLayout == layout
          else {
            return
          }

          layoutWillApply(layout)
          applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
          applyTransition(
            from: previousLayout,
            to: layout,
            displayInfo: displayInfo,
            snapshot: snapshot,
            window: window
          )

          DispatchQueue.main.async { [weak self, weak window] in
            guard
              let self,
              let window,
              transitionGeneration == generation,
              currentLayout == layout
            else {
              return
            }

            isApplyingLayoutTransition = false
            rememberPaneSizes(for: layout, window: window)
            saveFrame(window.frame, layout: layout)
          }
        }
        return
      } else if layout == .capture, displayChanged, let displayInfo {
        sizeCaptureWindow(for: displayInfo, window: window, anchor: .center)
        synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      } else {
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
      }

      currentDisplayInfo = displayInfo
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
      guard currentLayout == .capture else { return frameSize }
      let aspect = max(currentAspect, 0.0001)
      return NSSize(
        width: frameSize.width,
        height: (WindowChromeMetrics.totalToolbarHeight + (frameSize.width / aspect)).rounded()
      )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else { return }
      rememberPaneSizesForCurrentLayout(window: window)
      synchronizeCapturePaneWidthIfNeeded(for: currentLayout, window: window)
      saveCurrentFrame(from: notification)
    }

    func windowDidMove(_ notification: Notification) {
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
          reshapeCaptureWindow(window, anchor: .center)
        }
        rememberPaneSizes(for: layout, window: window)
        return
      }

      switch layout {
      case .capture:
        if let displayInfo {
          sizeCaptureWindow(for: displayInfo, window: window, anchor: .center)
        }
      case .network:
        setContentSize(Constants.networkContentSize, for: window, anchor: .center)
      case .both:
        setContentSize(Constants.bothContentSize, for: window, anchor: .center)
      }
      rememberPaneSizes(for: layout, window: window)
    }

    private func applyTransition(
      from previousLayout: WorkspaceLayout,
      to layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      snapshot: LayoutSnapshot,
      window: NSWindow
    ) {
      let currentContentSize = snapshot.workspaceSize

      switch (previousLayout, layout) {
      case (.capture, .both):
        let captureWidth = currentContentSize.width
        synchronizeCapturePaneWidth(captureWidth)
        adjustWorkspaceEdges(
          trailingBy: Constants.dividerWidth + rememberedNetworkPaneWidth,
          relativeTo: snapshot.frame,
          for: window
        )

      case (.both, .capture):
        let captureWidth = actualCapturePaneWidth(totalWidth: currentContentSize.width)
        let networkWidth = currentContentSize.width - captureWidth - Constants.dividerWidth
        synchronizeCapturePaneWidth(captureWidth)
        if let displayInfo {
          updateAspect(for: displayInfo)
        }
        adjustWorkspaceEdges(
          trailingBy: -(Constants.dividerWidth + networkWidth),
          relativeTo: snapshot.frame,
          for: window
        )

      case (.network, .both):
        let captureWidth = max(currentCapturePaneWidth, 260)
        adjustWorkspaceEdges(
          trailingBy: captureWidth + Constants.dividerWidth,
          relativeTo: snapshot.frame,
          for: window
        )

      case (.both, .network):
        let captureWidth = actualCapturePaneWidth(totalWidth: currentContentSize.width)
        let networkWidth = currentContentSize.width - captureWidth - Constants.dividerWidth
        rememberedNetworkPaneWidth = networkWidth
        adjustWorkspaceEdges(
          trailingBy: -(captureWidth + Constants.dividerWidth),
          relativeTo: snapshot.frame,
          for: window
        )

      case (.capture, .network):
        setContentSize(
          CGSize(width: rememberedNetworkPaneWidth, height: currentContentSize.height),
          for: window,
          anchor: .leading,
          relativeTo: snapshot.frame
        )

      case (.network, .capture):
        setCaptureContentWidth(
          max(currentCapturePaneWidth, 260),
          displayInfo: displayInfo,
          window: window,
          anchor: .trailing,
          relativeTo: snapshot.frame
        )

      default:
        break
      }
    }

    private func adjustWorkspaceEdges(
      leadingBy leadingDelta: CGFloat = 0,
      trailingBy trailingDelta: CGFloat = 0,
      relativeTo frame: NSRect,
      for window: NSWindow
    ) {
      let minX = frame.minX + leadingDelta
      let maxX = frame.maxX + trailingDelta
      window.setFrame(
        NSRect(
          x: minX,
          y: frame.minY,
          width: maxX - minX,
          height: frame.height
        ),
        display: true,
        animate: false
      )
    }

    private func applyMinimumSize(
      layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      to window: NSWindow
    ) {
      switch layout {
      case .capture:
        guard let displayInfo else {
          window.contentMinSize = sizeIncludingWindowChrome(
            CGSize(width: minimumCaptureEdge, height: minimumCaptureEdge)
          )
          return
        }
        window.contentMinSize = sizeIncludingWindowChrome(
          minimumCaptureContentSize(for: scaledContentSize(for: displayInfo))
        )
      case .network:
        window.contentMinSize = sizeIncludingWindowChrome(Constants.minimumNetworkContentSize)
      case .both:
        window.contentMinSize = sizeIncludingWindowChrome(Constants.minimumBothContentSize)
      }
    }

    private func sizeCaptureWindow(
      for displayInfo: DisplayInfo,
      window: NSWindow,
      anchor: HorizontalAnchor
    ) {
      let targetContentSize = scaledContentSize(for: displayInfo)
      updateAspect(for: displayInfo)
      setContentSize(targetContentSize, for: window, anchor: anchor)
    }

    private func setCaptureContentWidth(
      _ width: CGFloat,
      displayInfo: DisplayInfo?,
      window: NSWindow,
      anchor: HorizontalAnchor,
      relativeTo frame: NSRect? = nil
    ) {
      if let displayInfo {
        updateAspect(for: displayInfo)
      }
      let contentSize = CGSize(width: width, height: width / max(currentAspect, 0.0001))
      setContentSize(contentSize, for: window, anchor: anchor, relativeTo: frame)
    }

    private func reshapeCaptureWindow(_ window: NSWindow, anchor: HorizontalAnchor) {
      let contentWidth = window.frame.width
      let contentSize = CGSize(width: contentWidth, height: contentWidth / max(currentAspect, 0.0001))
      setContentSize(contentSize, for: window, anchor: anchor)
    }

    private func updateAspect(for displayInfo: DisplayInfo) {
      let contentSize = scaledContentSize(for: displayInfo)
      currentAspect = contentSize.width / max(contentSize.height, 1)
    }

    private func setContentSize(
      _ contentSize: CGSize,
      for window: NSWindow,
      anchor: HorizontalAnchor,
      relativeTo sourceFrame: NSRect? = nil
    ) {
      let frame = constrained(
        frameFor(
          contentSize: contentSize,
          anchor: anchor,
          relativeTo: sourceFrame ?? window.frame
        ),
        for: window
      )
      window.setFrame(frame, display: true, animate: false)
    }

    private func frameFor(
      contentSize: CGSize,
      anchor: HorizontalAnchor,
      relativeTo sourceFrame: NSRect
    ) -> NSRect {
      let width = contentSize.width
      let newHeight = contentSize.height + WindowChromeMetrics.totalToolbarHeight
      let x: CGFloat = switch anchor {
      case .leading:
        sourceFrame.minX
      case .center:
        sourceFrame.midX - (width / 2)
      case .trailing:
        sourceFrame.maxX - width
      }
      return NSRect(
        x: x,
        y: sourceFrame.maxY - newHeight,
        width: width,
        height: newHeight
      )
    }

    private func scaledContentSize(for display: DisplayInfo) -> CGSize {
      var width = display.size.width
      if let density = display.densityScale, density > 0 {
        width /= density
      }
      width = width.rounded()
      var height = width / display.aspectRatio
      let scale = max(minimumCaptureEdge / width, minimumCaptureEdge / height, 1)
      width *= scale
      height *= scale
      return CGSize(width: width.rounded(), height: height.rounded())
    }

    private func minimumCaptureContentSize(for contentSize: CGSize) -> CGSize {
      let scale = max(minimumCaptureEdge / contentSize.width, minimumCaptureEdge / contentSize.height)
      return CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }

    private func sizeIncludingWindowChrome(_ workspaceSize: CGSize) -> CGSize {
      CGSize(
        width: workspaceSize.width,
        height: workspaceSize.height + WindowChromeMetrics.totalToolbarHeight
      )
    }

    private func workspaceContentSize(for window: NSWindow) -> CGSize {
      CGSize(
        width: window.frame.width,
        height: max(window.frame.height - WindowChromeMetrics.totalToolbarHeight, 0)
      )
    }

    private func actualCapturePaneWidth(totalWidth: CGFloat) -> CGFloat {
      min(
        max(currentCapturePaneWidth, 260),
        max(totalWidth - Constants.minimumNetworkContentSize.width, 260)
      )
    }

    private func rememberPaneSizesForCurrentLayout(window: NSWindow) {
      guard let currentLayout else { return }
      rememberPaneSizes(for: currentLayout, window: window)
    }

    private func rememberPaneSizes(for layout: WorkspaceLayout, window: NSWindow) {
      let contentWidth = window.frame.width
      switch layout {
      case .capture:
        currentCapturePaneWidth = contentWidth
      case .network:
        rememberedNetworkPaneWidth = max(contentWidth, Constants.minimumNetworkContentSize.width)
      case .both:
        let captureWidth = actualCapturePaneWidth(totalWidth: contentWidth)
        rememberedNetworkPaneWidth = max(
          contentWidth - captureWidth - Constants.dividerWidth,
          Constants.minimumNetworkContentSize.width
        )
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
      let width = max(width.rounded(), 260)
      currentCapturePaneWidth = width
      guard abs(pendingCapturePaneWidth - width) > 0.5 else { return }
      pendingCapturePaneWidth = width
      guard let capturePaneWidthChanged else { return }
      DispatchQueue.main.async {
        capturePaneWidthChanged(width)
      }
    }

    private func constrained(_ frame: NSRect, for window: NSWindow) -> NSRect {
      guard let screen = window.screen ?? NSScreen.main else { return frame }
      let visibleFrame = screen.visibleFrame
      let width = min(frame.width, visibleFrame.width)
      let height = min(frame.height, visibleFrame.height)
      let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
      let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
      return NSRect(x: x, y: y, width: width, height: height)
    }

    private func saveCurrentFrame(from notification: Notification) {
      guard let window = notification.object as? NSWindow, let currentLayout else { return }
      saveFrame(window.frame, layout: currentLayout)
    }

    private func saveFrame(_ frame: NSRect, layout: WorkspaceLayout) {
      UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey(layout))
    }

    private func storedFrame(layout: WorkspaceLayout) -> NSRect? {
      guard let value = UserDefaults.standard.string(forKey: frameKey(layout)) else { return nil }
      let frame = NSRectFromString(value)
      return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private func frameKey(_ layout: WorkspaceLayout) -> String {
      "workspace.windowFrame.\(layout.rawValue)"
    }
  }
}

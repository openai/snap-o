import AppKit
import QuartzCore
import SwiftUI

struct WorkspaceLayoutTransition: Equatable {
  enum Pane: Equatable {
    case capture
    case network
  }

  let pane: Pane
  let fromLayout: WorkspaceLayout
  let toLayout: WorkspaceLayout
  let initialWindowWidth: CGFloat
  let finalWindowWidth: CGFloat
  let initialCapturePaneWidth: CGFloat
  let finalCapturePaneWidth: CGFloat
  let networkPaneWidth: CGFloat

  func progress(windowWidth: CGFloat) -> CGFloat {
    let distance = finalWindowWidth - initialWindowWidth
    guard abs(distance) > 0.5 else { return 1 }
    return min(max((windowWidth - initialWindowWidth) / distance, 0), 1)
  }

  func capturePaneWidth(windowWidth: CGFloat) -> CGFloat {
    let progress = progress(windowWidth: windowWidth)
    return initialCapturePaneWidth
      + ((finalCapturePaneWidth - initialCapturePaneWidth) * progress)
  }
}

enum WorkspaceLayoutPresentationEvent {
  case transitionWillBegin(WorkspaceLayoutTransition)
  case layoutDidApply(WorkspaceLayout)
}

/// Owns the main workspace window's aspect constraint and frame persistence.
/// Layout transitions preserve pane sizes while the window absorbs the added
/// or removed pane.
struct WindowSizingController: NSViewRepresentable {
  let displayInfo: DisplayInfo?
  let layout: WorkspaceLayout
  let capturePaneWidth: CGFloat
  let capturePaneWidthChanged: @MainActor (CGFloat) -> Void
  let presentationChanged: @MainActor (WorkspaceLayoutPresentationEvent) -> Void

  static let minimumCaptureEdge: CGFloat = 240
  static let minimumCapturePaneEdge: CGFloat = 260

  static func minimumCaptureContentSize(aspectRatio: CGFloat?) -> CGSize {
    guard let aspectRatio, aspectRatio > 0 else {
      return CGSize(width: minimumCaptureEdge, height: minimumCaptureEdge)
    }
    return CGSize(
      width: minimumCaptureEdge * max(aspectRatio, 1),
      height: minimumCaptureEdge * max(1 / aspectRatio, 1)
    )
  }

  static func minimumCapturePaneWidth(aspectRatio: CGFloat?) -> CGFloat {
    max(
      minimumCapturePaneEdge,
      minimumCaptureContentSize(aspectRatio: aspectRatio).width
    )
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
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
        presentationChanged: presentationChanged
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
      presentationChanged: presentationChanged
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSWindowDelegate {
    private struct LayoutSnapshot {
      let frame: NSRect
      let workspaceSize: CGSize
    }

    private struct LayoutChange {
      let previousLayout: WorkspaceLayout
      let layout: WorkspaceLayout
      let displayInfo: DisplayInfo?
      let snapshot: LayoutSnapshot
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
    private var currentAspect: CGFloat = 1
    private var currentLayout: WorkspaceLayout?
    private var currentDisplayInfo: DisplayInfo?
    private var currentCapturePaneWidth = WorkspaceLayoutController.defaultCapturePaneWidth
    private var rememberedNetworkPaneWidth = Constants.defaultNetworkPaneWidth
    private var pendingLayout: WorkspaceLayout = .capture
    private var pendingDisplayInfo: DisplayInfo?
    private var pendingCapturePaneWidth = WorkspaceLayoutController.defaultCapturePaneWidth
    private var capturePaneWidthChanged: (@MainActor (CGFloat) -> Void)?
    private var presentationChanged: (@MainActor (WorkspaceLayoutPresentationEvent) -> Void)?
    private var transitionGeneration = 0
    private var isApplyingLayoutTransition = false

    func attach(to window: NSWindow) {
      guard self.window !== window else { return }
      self.window = window
      window.delegate = self
      update(
        layout: pendingLayout,
        displayInfo: pendingDisplayInfo,
        capturePaneWidth: pendingCapturePaneWidth,
        capturePaneWidthChanged: capturePaneWidthChanged ?? { _ in },
        presentationChanged: presentationChanged ?? { _ in }
      )
    }

    func update(
      layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      capturePaneWidth: CGFloat,
      capturePaneWidthChanged: @escaping @MainActor (CGFloat) -> Void,
      presentationChanged: @escaping @MainActor (WorkspaceLayoutPresentationEvent) -> Void
    ) {
      pendingLayout = layout
      pendingDisplayInfo = displayInfo
      pendingCapturePaneWidth = capturePaneWidth
      self.capturePaneWidthChanged = capturePaneWidthChanged
      self.presentationChanged = presentationChanged
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
        currentDisplayInfo = displayInfo
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
        applyInitialFrame(for: layout, displayInfo: displayInfo, to: window)
        ensureMinimumBothContentSize(displayInfo: displayInfo, window: window)
        synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      } else if layoutChanged, let previousLayout {
        let snapshot = LayoutSnapshot(
          frame: window.frame,
          workspaceSize: workspaceContentSize(for: window)
        )
        rememberPaneSizes(for: previousLayout, window: window)
        saveFrame(snapshot.frame, layout: previousLayout)
        let transition = workspaceTransition(
          from: previousLayout,
          to: layout,
          workspaceSize: snapshot.workspaceSize,
          displayInfo: displayInfo
        )

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

          if let transition {
            presentationChanged(.transitionWillBegin(transition))
          } else {
            presentationChanged(.layoutDidApply(layout))
          }
          applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)

          DispatchQueue.main.async { [weak self, weak window] in
            guard
              let self,
              let window,
              transitionGeneration == generation,
              currentLayout == layout
            else {
              return
            }

            applyTransition(
              LayoutChange(
                previousLayout: previousLayout,
                layout: layout,
                displayInfo: displayInfo,
                snapshot: snapshot
              ),
              window: window
            ) { [weak self, weak window] in
              guard
                let self,
                let window,
                transitionGeneration == generation,
                currentLayout == layout
              else {
                return
              }

              presentationChanged(.layoutDidApply(layout))
              isApplyingLayoutTransition = false
              ensureMinimumBothContentSize(displayInfo: displayInfo, window: window)
              rememberPaneSizes(for: layout, window: window)
              saveFrame(window.frame, layout: layout)
            }
          }
        }
        return
      } else if layout == .capture, displayChanged, let displayInfo {
        sizeCaptureWindow(for: displayInfo, window: window, anchor: .center)
        synchronizeCapturePaneWidthIfNeeded(for: layout, window: window)
      } else {
        applyMinimumSize(layout: layout, displayInfo: displayInfo, to: window)
        ensureMinimumBothContentSize(displayInfo: displayInfo, window: window)
      }

      currentDisplayInfo = displayInfo
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
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
      _ change: LayoutChange,
      window: NSWindow,
      completion: @escaping @MainActor () -> Void
    ) {
      let previousLayout = change.previousLayout
      let layout = change.layout
      let displayInfo = change.displayInfo
      let snapshot = change.snapshot
      let currentContentSize = snapshot.workspaceSize
      let targetFrame: NSRect?

      switch (previousLayout, layout) {
      case (.capture, .both):
        let captureWidth = currentContentSize.width
        synchronizeCapturePaneWidth(captureWidth)
        targetFrame = frameByAdjustingWorkspaceEdges(
          trailingBy: Constants.dividerWidth + rememberedNetworkPaneWidth,
          relativeTo: snapshot.frame
        )

      case (.both, .capture):
        if let previewSize = standaloneCaptureContentSize(
          workspaceSize: currentContentSize,
          displayInfo: displayInfo
        ) {
          if let displayInfo {
            updateAspect(for: displayInfo)
          }
          synchronizeCapturePaneWidth(previewSize.width)
          targetFrame = constrained(
            frameFor(
              contentSize: previewSize,
              anchor: .leading,
              relativeTo: snapshot.frame
            ),
            for: window
          )
        } else {
          let captureWidth = actualCapturePaneWidth(totalWidth: currentContentSize.width)
          let networkWidth = currentContentSize.width - captureWidth - Constants.dividerWidth
          synchronizeCapturePaneWidth(captureWidth)
          targetFrame = frameByAdjustingWorkspaceEdges(
            trailingBy: -(Constants.dividerWidth + networkWidth),
            relativeTo: snapshot.frame
          )
        }

      case (.network, .both):
        let captureWidth = max(
          currentCapturePaneWidth,
          WindowSizingController.minimumCapturePaneWidth(
            aspectRatio: displayInfo?.aspectRatio
          )
        )
        targetFrame = constrained(
          frameByAdjustingWorkspaceEdges(
            leadingBy: -(captureWidth + Constants.dividerWidth),
            relativeTo: snapshot.frame
          ),
          for: window
        )

      case (.both, .network):
        let captureWidth = actualCapturePaneWidth(totalWidth: currentContentSize.width)
        let networkWidth = currentContentSize.width - captureWidth - Constants.dividerWidth
        rememberedNetworkPaneWidth = networkWidth
        targetFrame = frameByAdjustingWorkspaceEdges(
          leadingBy: captureWidth + Constants.dividerWidth,
          relativeTo: snapshot.frame
        )

      case (.capture, .network):
        targetFrame = constrained(
          frameFor(
            contentSize: CGSize(
              width: rememberedNetworkPaneWidth,
              height: currentContentSize.height
            ),
            anchor: .leading,
            relativeTo: snapshot.frame
          ),
          for: window
        )

      case (.network, .capture):
        if let displayInfo {
          updateAspect(for: displayInfo)
        }
        let captureWidth = max(
          currentCapturePaneWidth,
          WindowSizingController.minimumCapturePaneWidth(
            aspectRatio: displayInfo?.aspectRatio
          )
        )
        targetFrame = constrained(
          frameFor(
            contentSize: CGSize(
              width: captureWidth,
              height: captureWidth / max(currentAspect, 0.0001)
            ),
            anchor: .trailing,
            relativeTo: snapshot.frame
          ),
          for: window
        )

      default:
        targetFrame = nil
      }

      guard let targetFrame else {
        completion()
        return
      }
      animate(window: window, to: targetFrame, completion: completion)
    }

    private func workspaceTransition(
      from previousLayout: WorkspaceLayout,
      to layout: WorkspaceLayout,
      workspaceSize: CGSize,
      displayInfo: DisplayInfo?
    ) -> WorkspaceLayoutTransition? {
      let initialCaptureWidth: CGFloat
      let finalCaptureWidth: CGFloat
      let networkWidth: CGFloat
      let finalWindowWidth: CGFloat
      let pane: WorkspaceLayoutTransition.Pane

      switch (previousLayout, layout) {
      case (.capture, .both):
        pane = .network
        initialCaptureWidth = workspaceSize.width
        finalCaptureWidth = initialCaptureWidth
        networkWidth = rememberedNetworkPaneWidth
        finalWindowWidth = finalCaptureWidth + Constants.dividerWidth + networkWidth
      case (.both, .capture):
        pane = .network
        initialCaptureWidth = actualCapturePaneWidth(totalWidth: workspaceSize.width)
        finalCaptureWidth = standaloneCaptureContentSize(
          workspaceSize: workspaceSize,
          displayInfo: displayInfo
        )?.width ?? initialCaptureWidth
        networkWidth = workspaceSize.width - initialCaptureWidth - Constants.dividerWidth
        finalWindowWidth = finalCaptureWidth
      case (.network, .both):
        pane = .capture
        initialCaptureWidth = max(
          currentCapturePaneWidth,
          WindowSizingController.minimumCapturePaneWidth(
            aspectRatio: displayInfo?.aspectRatio
          )
        )
        finalCaptureWidth = initialCaptureWidth
        networkWidth = workspaceSize.width
        finalWindowWidth = finalCaptureWidth + Constants.dividerWidth + networkWidth
      case (.both, .network):
        pane = .capture
        initialCaptureWidth = actualCapturePaneWidth(totalWidth: workspaceSize.width)
        finalCaptureWidth = initialCaptureWidth
        networkWidth = workspaceSize.width - initialCaptureWidth - Constants.dividerWidth
        finalWindowWidth = networkWidth
      default:
        return nil
      }

      return WorkspaceLayoutTransition(
        pane: pane,
        fromLayout: previousLayout,
        toLayout: layout,
        initialWindowWidth: workspaceSize.width,
        finalWindowWidth: finalWindowWidth,
        initialCapturePaneWidth: initialCaptureWidth,
        finalCapturePaneWidth: finalCaptureWidth,
        networkPaneWidth: networkWidth
      )
    }

    private func standaloneCaptureContentSize(
      workspaceSize: CGSize,
      displayInfo: DisplayInfo?
    ) -> CGSize? {
      guard let displayInfo else { return nil }
      return captureContentSizeRespectingMinimum(
        fittedCapturePreviewSize(
          paneWidth: actualCapturePaneWidth(totalWidth: workspaceSize.width),
          paneHeight: workspaceSize.height,
          aspectRatio: displayInfo.aspectRatio
        )
      )
    }

    private func frameByAdjustingWorkspaceEdges(
      leadingBy leadingDelta: CGFloat = 0,
      trailingBy trailingDelta: CGFloat = 0,
      relativeTo frame: NSRect
    ) -> NSRect {
      let minX = frame.minX + leadingDelta
      let maxX = frame.maxX + trailingDelta
      return NSRect(
        x: minX,
        y: frame.minY,
        width: maxX - minX,
        height: frame.height
      )
    }

    private func animate(
      window: NSWindow,
      to frame: NSRect,
      completion: @escaping @MainActor () -> Void
    ) {
      guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
        window.setFrame(frame, display: true, animate: false)
        completion()
        return
      }

      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.24
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      } completionHandler: {
        Task { @MainActor in
          completion()
        }
      }
    }

    private func applyMinimumSize(
      layout: WorkspaceLayout,
      displayInfo: DisplayInfo?,
      to window: NSWindow
    ) {
      switch layout {
      case .capture:
        window.contentMinSize = sizeIncludingWindowChrome(
          WindowSizingController.minimumCaptureContentSize(
            aspectRatio: displayInfo?.aspectRatio
          )
        )
      case .network:
        window.contentMinSize = sizeIncludingWindowChrome(Constants.minimumNetworkContentSize)
      case .both:
        window.contentMinSize = sizeIncludingWindowChrome(
          minimumBothContentSize(displayInfo: displayInfo)
        )
      }
    }

    private func minimumBothContentSize(displayInfo: DisplayInfo?) -> CGSize {
      let captureSize = WindowSizingController.minimumCaptureContentSize(
        aspectRatio: displayInfo?.aspectRatio
      )
      let captureWidth = WindowSizingController.minimumCapturePaneWidth(
        aspectRatio: displayInfo?.aspectRatio
      )
      return CGSize(
        width: max(
          Constants.minimumBothContentSize.width,
          captureWidth + Constants.dividerWidth + Constants.minimumNetworkContentSize.width
        ),
        height: max(Constants.minimumBothContentSize.height, captureSize.height)
      )
    }

    private func ensureMinimumBothContentSize(
      displayInfo: DisplayInfo?,
      window: NSWindow
    ) {
      guard currentLayout == .both else { return }
      let minimumSize = minimumBothContentSize(displayInfo: displayInfo)
      let currentSize = workspaceContentSize(for: window)
      let targetSize = CGSize(
        width: max(currentSize.width, minimumSize.width),
        height: max(currentSize.height, minimumSize.height)
      )
      guard targetSize != currentSize else { return }
      setContentSize(targetSize, for: window, anchor: .leading)
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
      let minimumCaptureEdge = WindowSizingController.minimumCaptureEdge
      let scale = max(minimumCaptureEdge / width, minimumCaptureEdge / height, 1)
      width *= scale
      height *= scale
      return CGSize(width: width.rounded(), height: height.rounded())
    }

    private func captureContentSizeRespectingMinimum(_ contentSize: CGSize) -> CGSize {
      let minimumCaptureEdge = WindowSizingController.minimumCaptureEdge
      let scale = max(
        minimumCaptureEdge / contentSize.width,
        minimumCaptureEdge / contentSize.height,
        1
      )
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
      let minimumWidth = WindowSizingController.minimumCapturePaneWidth(
        aspectRatio: currentDisplayInfo?.aspectRatio
      )
      return min(
        max(currentCapturePaneWidth, minimumWidth),
        max(totalWidth - Constants.minimumNetworkContentSize.width, minimumWidth)
      )
    }

    private func fittedCapturePreviewSize(
      paneWidth: CGFloat,
      paneHeight: CGFloat,
      aspectRatio: CGFloat
    ) -> CGSize {
      let aspectRatio = max(aspectRatio, 0.0001)
      let width = min(paneWidth, paneHeight * aspectRatio)
      return CGSize(width: width, height: width / aspectRatio)
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
      let width = max(
        width.rounded(),
        WindowSizingController.minimumCapturePaneWidth(
          aspectRatio: currentDisplayInfo?.aspectRatio
        )
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
      guard let screen = window.screen ?? NSScreen.main else { return frame }
      let visibleFrame = screen.visibleFrame
      let width = min(max(frame.width, window.minSize.width), visibleFrame.width)
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

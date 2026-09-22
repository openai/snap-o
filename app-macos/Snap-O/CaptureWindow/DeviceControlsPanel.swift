import AppKit
import SwiftUI

/// Anchors a nonactivating child panel without taking space from the capture pane.
struct DeviceControlsPanel<Content: View>: NSViewRepresentable {
  let placement: DeviceControlsPlacement
  @ViewBuilder let content: () -> Content

  func makeNSView(context: Context) -> DeviceControlsAnchorView {
    DeviceControlsAnchorView()
  }

  func updateNSView(_ view: DeviceControlsAnchorView, context: Context) {
    view.update(placement: placement, content: AnyView(content()))
  }

  static func dismantleNSView(_ view: DeviceControlsAnchorView, coordinator: ()) {
    view.detach()
  }
}

@MainActor
final class DeviceControlsAnchorView: NSView {
  private(set) var panel: NSPanel?
  private var host: DeviceControlsHostingView?
  private var placement = DeviceControlsPlacement.left
  private var observers: [NSObjectProtocol] = []
  private var updateScheduled = false
  private var isAttached = false

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    detach()
    guard let window else { return }
    isAttached = true
    let center = NotificationCenter.default
    for name in [
      NSWindow.didMoveNotification, NSWindow.didResizeNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification
    ] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleUpdate() }
      })
    }
    observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.detach() }
    })
    observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleUpdate() }
    })
    observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
    })
    scheduleUpdate()
  }

  override func layout() {
    super.layout()
    scheduleUpdate()
  }

  func update(placement: DeviceControlsPlacement, content: AnyView) {
    self.placement = placement
    if let host {
      host.rootView = content
    } else {
      let host = DeviceControlsHostingView(rootView: content)
      host.sizingOptions = [.intrinsicContentSize]
      host.safeAreaRegions = []
      host.sizeChanged = { [weak self] in self?.scheduleUpdate() }
      self.host = host
    }
    scheduleUpdate()
  }

  func detach() {
    isAttached = false
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    if let panel { panel.parent?.removeChildWindow(panel) }
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
  }

  private func scheduleUpdate() {
    guard !updateScheduled else { return }
    updateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      updateScheduled = false
      updatePanel()
    }
  }

  private func updatePanel() {
    guard isAttached, let window, let host else { return }
    guard NSApp.isActive, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
          !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0 else {
      panel?.orderOut(nil)
      return
    }
    let panel: NSPanel
    if let existing = self.panel {
      panel = existing
    } else {
      panel = DeviceControlsWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.hidesOnDeactivate = true
      panel.animationBehavior = .none
      panel.collectionBehavior = [.fullScreenAuxiliary]
      panel.contentView = host
      self.panel = panel
    }
    let captureFrame = window.convertToScreen(convert(bounds, to: nil))
    let size = host.fittingSize
    let frame = Self.panelFrame(
      placement: placement, size: size, windowFrame: window.frame, captureFrame: captureFrame,
      screenFrame: window.screen?.visibleFrame ?? window.frame
    )
    if panel.frame != frame { panel.setFrame(frame, display: true) }
    panel.appearance = window.effectiveAppearance
    panel.level = window.level
    if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
    if !panel.isVisible { panel.order(.above, relativeTo: window.windowNumber) }
  }

  static func panelFrame(
    placement: DeviceControlsPlacement, size: CGSize,
    windowFrame: CGRect, captureFrame: CGRect, screenFrame: CGRect
  ) -> CGRect {
    let gap: CGFloat = 8
    let origin = switch placement {
    case .left:
      CGPoint(x: windowFrame.minX - gap - size.width, y: captureFrame.maxY - size.height)
    case .below:
      CGPoint(x: captureFrame.midX - size.width / 2, y: windowFrame.minY - gap - size.height)
    }
    // Keep the controls reachable at screen edges without resizing or moving the capture window.
    return CGRect(
      x: min(max(origin.x, screenFrame.minX), max(screenFrame.minX, screenFrame.maxX - size.width)),
      y: min(max(origin.y, screenFrame.minY), max(screenFrame.minY, screenFrame.maxY - size.height)),
      width: size.width, height: size.height
    )
  }
}

private final class DeviceControlsWindow: NSPanel {
  override var canBecomeKey: Bool {
    false
  }

  override var canBecomeMain: Bool {
    false
  }
}

private final class DeviceControlsHostingView: NSHostingView<AnyView> {
  var sizeChanged: (() -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    sizeChanged?()
  }
}

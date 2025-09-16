import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct LivePreviewRenderer {
  let session: LivePreviewSession
  let deviceID: String
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, CGPoint) -> Void
}

struct LivePreviewView: NSViewRepresentable {
  let renderer: LivePreviewRenderer

  func makeNSView(context: Context) -> LivePreviewDisplayView {
    let view = LivePreviewDisplayView()
    view.wantsLayer = true
    if view.layer == nil { view.layer = CALayer() }
    return view
  }

  func updateNSView(_ nsView: LivePreviewDisplayView, context: Context) {
    nsView.update(with: renderer)
  }

  static func dismantleNSView(_ nsView: LivePreviewDisplayView, coordinator: Void) {
    nsView.update(with: nil)
  }
}

final class LivePreviewDisplayView: NSView {
  private var renderer: LivePreviewRenderer?
  private var trackingArea: NSTrackingArea?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var endedLivePreviewTrace = false

  private var pointerState = PointerState()
  private let hoverThrottleInterval: TimeInterval = 1.0 / 45.0
  private let dragThrottleInterval: TimeInterval = 1.0 / 60.0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureLayerIfNeeded()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureLayerIfNeeded()
  }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  func update(with renderer: LivePreviewRenderer?) {
    if self.renderer?.deviceID != renderer?.deviceID {
      detachSession()
    }
    self.renderer = renderer
    attachSession()
  }

  private func configureLayerIfNeeded() {
    guard displayLayer.superlayer == nil else { return }
    wantsLayer = true
    layer?.addSublayer(displayLayer)
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor.black.cgColor
    displayLayer.frame = bounds
    displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
  }

  private func attachSession() {
    guard let session = renderer?.session else { return }
    session.sampleBufferHandler = { [weak self] sample in
      self?.enqueue(sample)
    }
    endedLivePreviewTrace = false
  }

  private func detachSession() {
    renderer?.session.sampleBufferHandler = nil
    displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    endedLivePreviewTrace = false
  }

  private func enqueue(_ sample: CMSampleBuffer) {
    guard displayLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return }
    displayLayer.sampleBufferRenderer.enqueue(sample)
    if !endedLivePreviewTrace {
      endedLivePreviewTrace = true
      Perf.step(.appFirstSnapshot, "after: Start Live Preview")
      Perf.end(.livePreviewStart, finalLabel: "first frame enqueued")
      Perf.end(.appFirstSnapshot, finalLabel: "first media appeared (live)")
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    trackingArea = area
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) { handlePointer(.hoverEnter, event: event) }
  override func mouseMoved(with event: NSEvent) { handlePointer(.hoverMove, event: event) }
  override func mouseExited(with event: NSEvent) { handlePointer(.hoverExit, event: event) }
  override func mouseDown(with event: NSEvent) { handlePointer(.down, event: event) }
  override func mouseDragged(with event: NSEvent) { handlePointer(.drag, event: event) }
  override func mouseUp(with event: NSEvent) { handlePointer(.up, event: event) }

  private enum PointerPhase { case hoverEnter, hoverMove, hoverExit, down, drag, up }

  private func handlePointer(_ phase: PointerPhase, event: NSEvent) {
    guard renderer != nil else { return }
    let devicePoint = convertToDevicePoint(event: event)

    switch phase {
    case .hoverEnter:
      guard let devicePoint else { return }
      pointerState.lastDeviceLocation = devicePoint
      pointerState.lastHoverTimestamp = event.timestamp
      sendPointer(.move, .mouse, devicePoint)

    case .hoverMove:
      guard !pointerState.isPointerDown, let devicePoint,
            shouldSendHoverEvent(at: event.timestamp) else { return }
      pointerState.lastDeviceLocation = devicePoint
      sendPointer(.move, .mouse, devicePoint)

    case .hoverExit:
      guard !pointerState.isPointerDown,
            let devicePoint = devicePoint ?? pointerState.lastDeviceLocation else { return }
      pointerState.lastDeviceLocation = devicePoint
      pointerState.lastHoverTimestamp = 0
      sendPointer(.move, .mouse, devicePoint)
      sendPointer(.cancel, .mouse, devicePoint)

    case .down:
      guard let devicePoint else { return }
      pointerState.isPointerDown = true
      pointerState.lastDeviceLocation = devicePoint
      pointerState.lastDragTimestamp = event.timestamp
      sendPointer(.down, .touchscreen, devicePoint)

    case .drag:
      guard pointerState.isPointerDown, let devicePoint,
            shouldSendDragEvent(at: event.timestamp) else { return }
      pointerState.lastDeviceLocation = devicePoint
      sendPointer(.move, .touchscreen, devicePoint)

    case .up:
      guard pointerState.isPointerDown,
            let devicePoint = devicePoint ?? pointerState.lastDeviceLocation else { return }
      pointerState.isPointerDown = false
      pointerState.lastDeviceLocation = devicePoint
      sendPointer(.up, .touchscreen, devicePoint)
    }
  }

  private func shouldSendHoverEvent(at timestamp: TimeInterval) -> Bool {
    guard timestamp - pointerState.lastHoverTimestamp >= hoverThrottleInterval else { return false }
    pointerState.lastHoverTimestamp = timestamp
    return true
  }

  private func shouldSendDragEvent(at timestamp: TimeInterval) -> Bool {
    guard timestamp - pointerState.lastDragTimestamp >= dragThrottleInterval else { return false }
    pointerState.lastDragTimestamp = timestamp
    return true
  }

  private func sendPointer(
    _ action: LivePreviewPointerAction,
    _ source: LivePreviewPointerSource,
    _ location: CGPoint
  ) {
    renderer?.sendPointer(action, source, location)
  }

  private func convertToDevicePoint(event: NSEvent) -> CGPoint? {
    guard let size = renderer?.session.media?.size, size.width > 0, size.height > 0 else { return nil }
    let localPoint = convert(event.locationInWindow, from: nil)
    let fitted = fittedMediaRect(contentSize: size, in: bounds)
    guard fitted.contains(localPoint) else { return nil }
    let nx = (localPoint.x - fitted.minX) / fitted.width
    let ny = (localPoint.y - fitted.minY) / fitted.height
    return CGPoint(x: nx * size.width, y: ny * size.height)
  }

  private func fittedMediaRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
    let w = contentSize.width * scale
    let h = contentSize.height * scale
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
  }

  private struct PointerState {
    var isPointerDown = false
    var lastHoverTimestamp: TimeInterval = 0
    var lastDragTimestamp: TimeInterval = 0
    var lastDeviceLocation: CGPoint?
  }
}

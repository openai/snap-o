import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct LivePreviewView: NSViewRepresentable {
  // Observable is optional; SwiftUI will re-run updateNSView when this changes anyway.
  @ObservedObject var controller: CaptureController

  func makeNSView(context: Context) -> PointerTrackingView {
    let view = PointerTrackingView()
    view.wantsLayer = true
    if view.layer == nil { view.layer = CALayer() }
    view.configureIfNeeded()
    view.controller = controller
    view.attachToSession()
    return view
  }

  func updateNSView(_ nsView: PointerTrackingView, context: Context) {
    nsView.controller = controller
    nsView.attachToSession()
  }

  static func dismantleNSView(_ nsView: PointerTrackingView, coordinator: Void) {
    nsView.teardown()
  }
}

final class PointerTrackingView: NSView {
  weak var controller: CaptureController?

  private var trackingArea: NSTrackingArea?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var endedLivePreviewTrace = false

  private var pointerState = PointerState()
  private let hoverThrottleInterval: TimeInterval = 1.0 / 45.0
  private let dragThrottleInterval: TimeInterval = 1.0 / 60.0

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  func configureIfNeeded() {
    guard displayLayer.superlayer == nil else { return }
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor.black.cgColor
    displayLayer.frame = bounds
    displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    layer?.addSublayer(displayLayer)
  }

  func attachToSession() {
    controller?.livePreviewSession?.sampleBufferHandler = { [weak self] sample in
      self?.enqueue(sample)
    }
  }

  func teardown() {
    controller?.livePreviewSession?.sampleBufferHandler = nil
    displayLayer.sampleBufferRenderer.flush()
    displayLayer.sampleBufferRenderer.stopRequestingMediaData()
  }

  private func enqueue(_ sample: CMSampleBuffer) {
    displayLayer.sampleBufferRenderer.enqueue(sample)
    if !endedLivePreviewTrace {
      endedLivePreviewTrace = true
      Perf.step(.appFirstSnapshot, "after: Start Live Preview")
      Perf.end(.livePreviewStart, finalLabel: "first frame enqueued")
      Perf.end(.appFirstSnapshot, finalLabel: "first media appeared (live)")
    }
  }

  // MARK: - Tracking

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

  // MARK: - Pointer pipeline

  enum PointerPhase { case hoverEnter, hoverMove, hoverExit, down, drag, up }

  private func handlePointer(_ phase: PointerPhase, event: NSEvent) {
    guard controller?.isLivePreviewActive == true else { return }
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
    controller?.sendPointerEvent(action: action, source: source, location: location)
  }

  private func convertToDevicePoint(event: NSEvent) -> CGPoint? {
    guard let mediaSize = livePreviewMediaSize(), mediaSize.width > 0, mediaSize.height > 0 else { return nil }
    let localPoint = convert(event.locationInWindow, from: nil)
    let fitted = fittedMediaRect(contentSize: mediaSize, in: bounds)
    guard fitted.contains(localPoint) else { return nil }
    let nx = (localPoint.x - fitted.minX) / fitted.width
    let ny = (localPoint.y - fitted.minY) / fitted.height
    return CGPoint(x: nx * mediaSize.width, y: ny * mediaSize.height)
  }

  private func fittedMediaRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
    let w = contentSize.width * scale
    let h = contentSize.height * scale
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
  }

  private func livePreviewMediaSize() -> CGSize? {
    guard let controller,
          case .livePreview(_, let media) = controller.mode else { return nil }
    return media.size
  }

  private struct PointerState {
    var isPointerDown = false
    var lastHoverTimestamp: TimeInterval = 0
    var lastDragTimestamp: TimeInterval = 0
    var lastDeviceLocation: CGPoint?
  }
}

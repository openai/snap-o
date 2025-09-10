import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct LivePreviewView: NSViewRepresentable {
  @ObservedObject var controller: CaptureController

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = PointerTrackingView()
    view.wantsLayer = true
    if view.layer == nil {
      view.layer = CALayer()
    }
    view.coordinator = context.coordinator
    context.coordinator.setup(in: view, controller: controller)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let pointerView = nsView as? PointerTrackingView else { return }
    pointerView.coordinator = context.coordinator
    context.coordinator.controller = controller
    context.coordinator.attachToSession()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let pointerView = nsView as? PointerTrackingView {
      pointerView.coordinator = nil
    }
    coordinator.teardown()
  }

  final class PointerTrackingView: NSView {
    weak var coordinator: Coordinator?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea {
        removeTrackingArea(trackingArea)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [
          .activeInActiveApp,
          .mouseEnteredAndExited,
          .mouseMoved,
          .inVisibleRect
        ],
        owner: self,
        userInfo: nil
      )
      trackingArea = area
      addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
      coordinator?.handlePointer(.hoverEnter, event: event, in: self)
    }

    override func mouseMoved(with event: NSEvent) {
      coordinator?.handlePointer(.hoverMove, event: event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
      coordinator?.handlePointer(.hoverExit, event: event, in: self)
    }

    override func mouseDown(with event: NSEvent) {
      coordinator?.handlePointer(.down, event: event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
      coordinator?.handlePointer(.drag, event: event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
      coordinator?.handlePointer(.up, event: event, in: self)
    }
  }

  @MainActor
  final class Coordinator {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var controller: CaptureController?
    private var endedLivePreviewTrace = false
    private var pointerState = PointerState()

    private let hoverThrottleInterval: TimeInterval = 1.0 / 45.0
    private let dragThrottleInterval: TimeInterval = 1.0 / 60.0

    init() {
      displayLayer.videoGravity = .resizeAspect
      displayLayer.backgroundColor = NSColor.black.cgColor
    }

    func setup(in view: NSView, controller: CaptureController) {
      self.controller = controller
      displayLayer.frame = view.bounds
      displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      view.layer?.addSublayer(displayLayer)
      attachToSession()
    }

    func enqueue(_ sample: CMSampleBuffer) {
      displayLayer.sampleBufferRenderer.enqueue(sample)
      if !endedLivePreviewTrace {
        endedLivePreviewTrace = true
        Perf.step(.appFirstSnapshot, "after: Start Live Preview")
        Perf.end(.livePreviewStart, finalLabel: "first frame enqueued")
        Perf.end(.appFirstSnapshot, finalLabel: "first media appeared (live)")
      }
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

    func handlePointer(_ phase: PointerPhase, event: NSEvent, in view: NSView) {
      guard controller?.isLivePreviewActive == true else { return }

      let mappedPoint = convertToDevicePoint(event: event, in: view)

      switch phase {
      case .hoverEnter:
        guard let location = mappedPoint else { return }
        pointerState.lastDeviceLocation = location
        pointerState.lastHoverTimestamp = event.timestamp
        sendPointer(action: .move, source: .mouse, location: location)
      case .hoverMove:
        guard !pointerState.isPointerDown else { return }
        guard let location = mappedPoint else { return }
        guard shouldSendHoverEvent(at: event.timestamp) else { return }
        pointerState.lastDeviceLocation = location
        sendPointer(action: .move, source: .mouse, location: location)
      case .hoverExit:
        guard !pointerState.isPointerDown else { return }
        guard let location = mappedPoint ?? pointerState.lastDeviceLocation else { return }
        pointerState.lastDeviceLocation = location
        pointerState.lastHoverTimestamp = 0
        sendPointer(action: .move, source: .mouse, location: location)
        sendPointer(action: .cancel, source: .mouse, location: location)
      case .down:
        guard let location = mappedPoint else { return }
        pointerState.isPointerDown = true
        pointerState.lastDeviceLocation = location
        pointerState.lastDragTimestamp = event.timestamp
        sendPointer(action: .down, source: .touchscreen, location: location)
      case .drag:
        guard pointerState.isPointerDown else { return }
        guard let location = mappedPoint else { return }
        guard shouldSendDragEvent(at: event.timestamp) else { return }
        pointerState.lastDeviceLocation = location
        sendPointer(action: .move, source: .touchscreen, location: location)
      case .up:
        guard pointerState.isPointerDown else { return }
        guard let location = mappedPoint ?? pointerState.lastDeviceLocation else { return }
        pointerState.isPointerDown = false
        pointerState.lastDeviceLocation = location
        sendPointer(action: .up, source: .touchscreen, location: location)
      }
    }

    private func shouldSendHoverEvent(at timestamp: TimeInterval) -> Bool {
      if timestamp - pointerState.lastHoverTimestamp < hoverThrottleInterval {
        return false
      }
      pointerState.lastHoverTimestamp = timestamp
      return true
    }

    private func shouldSendDragEvent(at timestamp: TimeInterval) -> Bool {
      if timestamp - pointerState.lastDragTimestamp < dragThrottleInterval {
        return false
      }
      pointerState.lastDragTimestamp = timestamp
      return true
    }

    private func sendPointer(
      action: LivePreviewPointerAction,
      source: LivePreviewPointerSource,
      location: CGPoint
    ) {
      controller?.sendPointerEvent(action: action, source: source, location: location)
    }

    private func convertToDevicePoint(event: NSEvent, in view: NSView) -> CGPoint? {
      guard let mediaSize = livePreviewMediaSize(), mediaSize.width > 0, mediaSize.height > 0 else {
        return nil
      }

      let localPoint = view.convert(event.locationInWindow, from: nil)
      let fittedRect = fittedMediaRect(contentSize: mediaSize, in: view.bounds)
      guard fittedRect.contains(localPoint) else { return nil }

      let normalizedX = (localPoint.x - fittedRect.minX) / fittedRect.width
      let normalizedY = (localPoint.y - fittedRect.minY) / fittedRect.height

      return CGPoint(x: normalizedX * mediaSize.width, y: normalizedY * mediaSize.height)
    }

    private func fittedMediaRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
      guard contentSize.width > 0, contentSize.height > 0 else { return .zero }
      guard bounds.width > 0, bounds.height > 0 else { return .zero }

      let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
      let width = contentSize.width * scale
      let height = contentSize.height * scale
      let originX = bounds.midX - width / 2.0
      let originY = bounds.midY - height / 2.0
      return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func livePreviewMediaSize() -> CGSize? {
      guard let controller else { return nil }
      guard case .livePreview(_, let media) = controller.mode else { return nil }
      return media.size
    }

    private struct PointerState {
      var isPointerDown = false
      var lastHoverTimestamp: TimeInterval = 0
      var lastDragTimestamp: TimeInterval = 0
      var lastDeviceLocation: CGPoint?
    }
  }

  enum PointerPhase {
    case hoverEnter
    case hoverMove
    case hoverExit
    case down
    case drag
    case up
  }
}

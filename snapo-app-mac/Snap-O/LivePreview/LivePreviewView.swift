import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Connects a live-preview session to its interactive AppKit surface.
struct LivePreviewRenderer {
  let operation: LivePreviewOperationHandle
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, CGPoint) -> Void

  var session: LivePreviewSession {
    operation.session
  }

  var deviceID: String {
    operation.deviceID
  }
}

struct LivePreviewRendererView: NSViewRepresentable {
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
  private var readyForDisplayObserver: NSObjectProtocol?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private let initialFrameLayer = CALayer()
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

  override var acceptsFirstResponder: Bool {
    true
  }

  override var isFlipped: Bool {
    true
  }

  func update(with renderer: LivePreviewRenderer?) {
    let shouldDetach: Bool = switch (self.renderer?.session, renderer?.session) {
    case (let lhs?, let rhs?): lhs !== rhs
    case (nil, nil): false
    default: true
    }
    if shouldDetach {
      detachSession()
    }
    self.renderer = renderer
    if shouldDetach {
      attachSession()
    }
  }

  private func configureLayerIfNeeded() {
    guard displayLayer.superlayer == nil else { return }
    wantsLayer = true
    layer?.addSublayer(displayLayer)
    layer?.addSublayer(initialFrameLayer)
    displayLayer.videoGravity = .resizeAspect
    updateDisplayLayerBackgroundColor()
    displayLayer.frame = bounds
    displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    initialFrameLayer.contentsGravity = .resizeAspect
    initialFrameLayer.frame = bounds
    initialFrameLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateDisplayLayerBackgroundColor()
  }

  private func updateDisplayLayerBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      displayLayer.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
    }
  }

  private func attachSession() {
    guard let renderer else { return }
    let session = renderer.session
    let operationID = renderer.operation.id
    session.initialFrameHandler = { [weak self] frame in
      self?.displayInitialFrame(frame, operationID: operationID)
    }
    session.sampleBufferHandler = { [weak self] sample in
      self?.enqueue(sample)
    }
    endedLivePreviewTrace = false
  }

  private func detachSession() {
    stopObservingDisplayReadiness()
    renderer?.session.initialFrameHandler = nil
    renderer?.session.sampleBufferHandler = nil
    displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    displayLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: .main) {}
    setInitialFrame(nil)
    endedLivePreviewTrace = false
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

  private func displayInitialFrame(_ image: CGImage, operationID: UUID) {
    guard renderer?.operation.id == operationID else { return }
    observeDisplayReadiness(operationID: operationID)
    guard !displayLayer.isReadyForDisplay else {
      hideInitialFrameIfReady(operationID: operationID)
      return
    }
    setInitialFrame(image)
    hideInitialFrameIfReady(operationID: operationID)
  }

  private func observeDisplayReadiness(operationID: UUID) {
    stopObservingDisplayReadiness()
    readyForDisplayObserver = NotificationCenter.default.addObserver(
      forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
      object: displayLayer,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.hideInitialFrameIfReady(operationID: operationID)
      }
    }
  }

  private func hideInitialFrameIfReady(operationID: UUID) {
    guard renderer?.operation.id == operationID,
          displayLayer.isReadyForDisplay else { return }
    renderer?.session.discardInitialFrame()
    setInitialFrame(nil)
    stopObservingDisplayReadiness()
  }

  private func stopObservingDisplayReadiness() {
    guard let readyForDisplayObserver else { return }
    NotificationCenter.default.removeObserver(readyForDisplayObserver)
    self.readyForDisplayObserver = nil
  }

  private func setInitialFrame(_ image: CGImage?) {
    if image == nil, initialFrameLayer.contents == nil { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    initialFrameLayer.contents = image
    CATransaction.commit()
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

  override func mouseEntered(with event: NSEvent) {
    handlePointer(.hoverEnter, event: event)
  }

  override func mouseMoved(with event: NSEvent) {
    handlePointer(.hoverMove, event: event)
  }

  override func mouseExited(with event: NSEvent) {
    handlePointer(.hoverExit, event: event)
  }

  override func mouseDown(with event: NSEvent) {
    handlePointer(.down, event: event)
  }

  override func mouseDragged(with event: NSEvent) {
    handlePointer(.drag, event: event)
  }

  override func mouseUp(with event: NSEvent) {
    handlePointer(.up, event: event)
  }

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

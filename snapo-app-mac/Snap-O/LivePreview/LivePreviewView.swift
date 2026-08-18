import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Connects a live-preview session to its interactive AppKit surface.
struct LivePreviewRenderer {
  let operation: LivePreviewOperationHandle
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, CGPoint, CGSize) -> Void

  var session: LivePreviewSession {
    operation.session
  }

  var deviceID: String {
    operation.deviceID
  }
}

struct LivePreviewRendererView: NSViewRepresentable {
  let renderer: LivePreviewRenderer
  let fileStore: FileStore

  func makeNSView(context: Context) -> LivePreviewDisplayView {
    let view = LivePreviewDisplayView(fileStore: fileStore)
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

final class LivePreviewDisplayView: NSView, NSDraggingSource {
  private let fileStore: FileStore
  private let frameExporter = LivePreviewFrameExporter()
  private var renderer: LivePreviewRenderer?
  private var trackingArea: NSTrackingArea?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var endedLivePreviewTrace = false

  private var pointerState = PointerState()
  private let hoverThrottleInterval: TimeInterval = 1.0 / 45.0
  private let dragThrottleInterval: TimeInterval = 1.0 / 60.0
  private var frameDragOrigin: CGPoint?
  private var isDraggingFrame = false

  init(fileStore: FileStore) {
    self.fileStore = fileStore
    super.init(frame: .zero)
    configureLayerIfNeeded()
    toolTip = "Option-drag to capture the current frame"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
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
    displayLayer.videoGravity = .resizeAspect
    updateDisplayLayerBackgroundColor()
    displayLayer.frame = bounds
    displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
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
    endedLivePreviewTrace = false
    session.sampleBufferHandler = { [weak self] sample in
      self?.enqueue(sample)
    }
  }

  private func detachSession() {
    frameDragOrigin = nil
    isDraggingFrame = false
    pointerState = PointerState()
    renderer?.session.sampleBufferHandler = nil
    displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    displayLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: .main) {}
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
    if event.modifierFlags.contains(.option) {
      isDraggingFrame = true
      if convertToDevicePoint(event: event) != nil {
        frameDragOrigin = convert(event.locationInWindow, from: nil)
      }
      return
    }
    handlePointer(.down, event: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if isDraggingFrame {
      startFrameDragIfNeeded(with: event)
      return
    }
    handlePointer(.drag, event: event)
  }

  override func mouseUp(with event: NSEvent) {
    if isDraggingFrame {
      frameDragOrigin = nil
      isDraggingFrame = false
      return
    }
    handlePointer(.up, event: event)
  }

  private func startFrameDragIfNeeded(with event: NSEvent) {
    guard let origin = frameDragOrigin else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }
    frameDragOrigin = nil

    guard let pixelBuffer = displayLayer.sampleBufferRenderer.displayedPixelBuffer() else {
      NSSound.beep()
      return
    }
    do {
      let frame = try frameExporter.export(pixelBuffer, to: fileStore)
      let item = NSDraggingItem(pasteboardWriter: frame.url as NSURL)
      item.setDraggingFrame(fittedMediaRect(contentSize: frame.image.size, in: bounds), contents: frame.image)
      beginDraggingSession(with: [item], event: event, source: self)
    } catch {
      SnapOLog.ui.error("Unable to export live frame: \(error.localizedDescription, privacy: .public)")
      NSSound.beep()
    }
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    .copy
  }

  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
    true
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    frameDragOrigin = nil
    isDraggingFrame = false
  }

  private enum PointerPhase { case hoverEnter, hoverMove, hoverExit, down, drag, up }

  private func handlePointer(_ phase: PointerPhase, event: NSEvent) {
    guard renderer != nil, !isDraggingFrame else { return }
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
    guard let renderer, let size = renderer.session.media?.size else { return }
    renderer.sendPointer(action, source, location, size)
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

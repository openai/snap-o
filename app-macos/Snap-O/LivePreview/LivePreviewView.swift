import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Connects a live-preview session to its interactive AppKit surface.
struct LivePreviewRenderer {
  let operation: LivePreviewOperationHandle
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, [CGPoint], CGSize) -> Void

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
  let isVisible: Bool
  var thumbnail: LivePreviewThumbnail?
  var keyboard: (any LivePreviewKeyboardHandling)?
  var keyboardEnabled = false

  @Environment(\.captureImageCopied)
  private var imageCopied

  func makeNSView(context: Context) -> LivePreviewDisplayView {
    let view = LivePreviewDisplayView(fileStore: fileStore)
    view.wantsLayer = true
    if view.layer == nil { view.layer = CALayer() }
    return view
  }

  func updateNSView(_ nsView: LivePreviewDisplayView, context: Context) {
    nsView.imageCopied = imageCopied
    nsView.configureKeyboard(keyboard, enabled: keyboardEnabled)
    nsView.update(with: renderer, isVisible: isVisible, thumbnail: thumbnail)
  }

  static func dismantleNSView(_ nsView: LivePreviewDisplayView, coordinator: Void) {
    nsView.imageCopied = {}
    nsView.configureKeyboard(nil, enabled: false)
    nsView.update(with: nil)
  }
}

final class LivePreviewDisplayView: NSView, NSDraggingSource, NSMenuItemValidation {
  var imageCopied: () -> Void = {}
  var keyboard: (any LivePreviewKeyboardHandling)?
  var keyboardEnabled = false
  var keyboardArmed = false
  var markedText = NSAttributedString()
  var markedSelection = NSRange(location: 0, length: 0)

  var hasVisiblePreview: Bool {
    !displayLayer.isHidden && renderer != nil
  }

  private let fileStore: FileStore
  private let frameExporter = LivePreviewFrameExporter()
  private var renderer: LivePreviewRenderer?
  private weak var thumbnail: LivePreviewThumbnail?
  private var trackingArea: NSTrackingArea?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var endedLivePreviewTrace = false

  private var pointerState = PointerState()
  private var multitouch: LivePreviewMultitouch?
  private var gestureDisplaySize: CGSize?
  private var modifierMonitor: Any?
  private let touchOverlay = CAShapeLayer()
  private let hoverThrottleInterval: TimeInterval = 1.0 / 45.0
  private var frameDragOrigin: CGPoint?
  private var isDraggingFrame = false

  init(fileStore: FileStore) {
    self.fileStore = fileStore
    super.init(frame: .zero)
    configureLayerIfNeeded()
    toolTip = "Command-drag to capture the current frame"
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

  override func menu(for event: NSEvent) -> NSMenu? {
    window?.makeFirstResponder(self)
    let menu = NSMenu()
    // A separate menu action avoids AppKit's automatic icon for the standard Copy action.
    menu.addItem(withTitle: "Copy Image", action: #selector(copyPreviewFrame(_:)), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Save Image As…", action: #selector(saveImageAs(_:)), keyEquivalent: "").target = self
    return menu
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(paste(_:)) {
      return canSendKeyboardInput && NSPasteboard.general.string(forType: .string) != nil
    }
    if menuItem.action == #selector(copy(_:)), keyboardEnabled { return canSendKeyboardInput }
    return renderer != nil && displayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil
  }

  @objc
  func copy(_ sender: Any?) {
    if keyboardEnabled {
      sendKeyboard(.copy)
    } else {
      copyFrame(to: .general)
    }
  }

  @objc
  private func copyPreviewFrame(_ sender: Any?) {
    copyFrame(to: .general)
  }

  func copyFrame(to pasteboard: NSPasteboard) {
    guard let frame = exportCurrentFrame() else { return }
    pasteboard.clearContents()
    if pasteboard.writeObjects([frame.image]) {
      imageCopied()
    }
  }

  @objc
  private func saveImageAs(_ sender: Any?) {
    // Freeze the displayed frame before the save dialog opens while playback continues.
    guard let frame = exportCurrentFrame() else { return }
    let panel = NSSavePanel()
    panel.title = "Save Image As"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = frame.url.lastPathComponent
    panel.directoryURL = SaveLocation.defaultDirectory(for: .image)
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    do {
      try Data(contentsOf: frame.url).write(to: destination, options: .atomic)
      SaveLocation.setLastDirectoryURL(destination.deletingLastPathComponent(), for: .image)
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Unable to Save Image"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  func update(with renderer: LivePreviewRenderer?, isVisible: Bool = false, thumbnail: LivePreviewThumbnail? = nil) {
    if !isVisible {
      cancelPointerGesture()
      releaseKeyboardFocus()
    }
    // Keep decoding and retaining the latest frame without compositing hidden previews.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.isHidden = !isVisible
    CATransaction.commit()

    let shouldDetach: Bool = switch (self.renderer?.session, renderer?.session) {
    case (let lhs?, let rhs?): lhs !== rhs
    case (nil, nil): false
    default: true
    }
    if shouldDetach {
      detachSession()
    }
    if self.thumbnail !== thumbnail {
      detachThumbnail()
      self.thumbnail = thumbnail
    }
    self.renderer = renderer
    thumbnail?.videoRenderer = renderer == nil ? nil : displayLayer.sampleBufferRenderer
    if shouldDetach {
      attachSession()
    }
  }

  private func configureLayerIfNeeded() {
    guard displayLayer.superlayer == nil else { return }
    wantsLayer = true
    layer?.addSublayer(displayLayer)
    layer?.addSublayer(touchOverlay)
    touchOverlay.strokeColor = NSColor.white.cgColor
    touchOverlay.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
    touchOverlay.lineWidth = 1.5
    touchOverlay.shadowColor = NSColor.black.cgColor
    touchOverlay.shadowOpacity = 0.6
    touchOverlay.shadowRadius = 2
    touchOverlay.shadowOffset = .zero
    touchOverlay.isHidden = true
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
    #if PERF_TRACING
    Perf.startupEvent("renderer attach", deviceID: renderer.deviceID)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(logDisplayReadiness),
      name: NSNotification.Name.AVSampleBufferDisplayLayerReadyForDisplayDidChange,
      object: displayLayer
    )
    #endif
    endedLivePreviewTrace = false
    session.sampleBufferHandler = { [weak self] sample in
      self?.enqueue(sample)
    }
  }

  #if PERF_TRACING
  @objc
  private nonisolated func logDisplayReadiness() {
    Task { @MainActor [weak self] in
      guard let self, displayLayer.isReadyForDisplay, let renderer else { return }
      Perf.startupEvent("layer ready for display", deviceID: renderer.deviceID)
    }
  }
  #endif

  private func detachThumbnail() {
    guard thumbnail?.videoRenderer === displayLayer.sampleBufferRenderer else { return }
    thumbnail?.cacheLiveFrame()
    thumbnail?.videoRenderer = nil
  }

  private func detachSession() {
    releaseKeyboardFocus()
    #if PERF_TRACING
    NotificationCenter.default.removeObserver(
      self, name: NSNotification.Name.AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: displayLayer
    )
    #endif
    cancelPointerGesture()
    detachThumbnail()
    frameDragOrigin = nil
    isDraggingFrame = false
    pointerState = PointerState()
    renderer?.session.sampleBufferHandler = nil
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    endedLivePreviewTrace = false
  }

  private func enqueue(_ sample: CMSampleBuffer) {
    displayLayer.sampleBufferRenderer.enqueue(sample)
    if !endedLivePreviewTrace {
      endedLivePreviewTrace = true
      #if PERF_TRACING
      Perf.startupEvent("renderer first enqueue", deviceID: renderer?.deviceID)
      #endif

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

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    releaseKeyboardFocus()
    cancelPointerGesture()
    if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    modifierMonitor = nil
    NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    NotificationCenter.default.addObserver(
      self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(windowResignedKey), name: NSApplication.didResignActiveNotification, object: nil
    )
    modifierMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self, event.window === self.window, !displayLayer.isHidden else { return event }
      if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
         !visibleRect.contains(convert(event.locationInWindow, from: nil)) {
        releaseKeyboardFocus()
      }
      if event.type == .flagsChanged {
        flagsChanged(with: event)
      } else if event.type == .keyDown, event.keyCode == 53, cancelGestureForEscape() {
        return nil
      }
      return event
    }
  }

  @objc
  private func windowResignedKey() {
    releaseKeyboardFocus()
    cancelPointerGesture()
  }

  override func layout() {
    super.layout()
    updateTouchOverlay()
  }

  override func flagsChanged(with event: NSEvent) {
    let modifiers = event.modifierFlags
    guard !isDraggingFrame else { return }
    guard modifiers.contains(.option), !modifiers.contains(.command), !modifiers.contains(.control) else {
      if multitouch != nil { cancelPointerGesture() }
      return
    }
    guard !pointerState.isPointerDown, let window else { return }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if multitouch == nil, let normalized = normalizedPoint(point) {
      multitouch = LivePreviewMultitouch(pointer: normalized)
    }
    updateTouchOverlay()
  }

  func cancelGestureForEscape() -> Bool {
    guard multitouch != nil || pointerState.isPointerDown else { return false }
    cancelPointerGesture()
    return true
  }

  private func cancelPointerGesture() {
    if gestureDisplaySize != nil {
      sendMultitouch(.cancel)
    } else if pointerState.isPointerDown, let point = pointerState.lastDeviceLocation {
      sendPointer(.cancel, .touchscreen, point)
    }
    gestureDisplaySize = nil
    multitouch = nil
    pointerState = PointerState()
    updateTouchOverlay()
  }

  private func updateTouchOverlay() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let multitouch, !displayLayer.isHidden, let size = renderer?.session.media?.size else {
      touchOverlay.isHidden = true
      return
    }
    let rect = fittedMediaRect(contentSize: size, in: bounds)
    func local(_ point: CGPoint) -> CGPoint {
      CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
    let touches = CGMutablePath()
    for point in multitouch.locations {
      let point = local(point)
      touches.addEllipse(in: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
    }
    let center = local(multitouch.center)
    touches.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
    touchOverlay.path = touches
    touchOverlay.opacity = gestureDisplaySize == nil ? 0.65 : 1
    touchOverlay.isHidden = false
  }

  private func normalizedPoint(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
    guard let size = renderer?.session.media?.size, size.width > 0, size.height > 0 else { return nil }
    let rect = fittedMediaRect(contentSize: size, in: bounds)
    guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
    return CGPoint(
      x: min(1, max(0, (point.x - rect.minX) / rect.width)),
      y: min(1, max(0, (point.y - rect.minY) / rect.height))
    )
  }

  private func handleMultitouch(_ phase: PointerPhase, event: NSEvent) {
    if phase == .hoverExit, gestureDisplaySize == nil {
      multitouch = nil
      updateTouchOverlay()
      return
    }
    if let gestureDisplaySize, gestureDisplaySize != renderer?.session.media?.size {
      cancelPointerGesture()
      return
    }
    let local = convert(event.locationInWindow, from: nil)
    guard let point = normalizedPoint(local, clamp: gestureDisplaySize != nil) else { return }
    if multitouch == nil { multitouch = LivePreviewMultitouch(pointer: point) }
    multitouch?.move(to: point, translating: event.modifierFlags.contains(.shift))
    switch phase {
    case .down:
      gestureDisplaySize = renderer?.session.media?.size
      sendMultitouch(.down)
    case .drag:
      if gestureDisplaySize != nil { sendMultitouch(.move) }
    case .up:
      if gestureDisplaySize != nil { sendMultitouch(.up) }
      gestureDisplaySize = nil
    case .hoverEnter, .hoverMove, .hoverExit:
      break
    }
    updateTouchOverlay()
  }

  private func sendMultitouch(_ action: LivePreviewPointerAction) {
    guard let renderer, let multitouch, let size = gestureDisplaySize ?? renderer.session.media?.size else { return }
    let locations = multitouch.locations.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    renderer.sendPointer(action, .touchscreen, locations, size)
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
    window?.makeFirstResponder(self)
    if event.modifierFlags.contains(.control) {
      super.mouseDown(with: event)
      return
    }
    if event.modifierFlags.contains(.command) {
      isDraggingFrame = true
      if convertToDevicePoint(event: event) != nil {
        frameDragOrigin = convert(event.locationInWindow, from: nil)
      }
      return
    }
    if keyboardEnabled, convertToDevicePoint(event: event) != nil {
      keyboardArmed = true
    } else {
      releaseKeyboardFocus()
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

    guard let frame = exportCurrentFrame() else { return }
    let item = NSDraggingItem(pasteboardWriter: frame.url as NSURL)
    item.setDraggingFrame(fittedMediaRect(contentSize: frame.image.size, in: bounds), contents: frame.image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  private func exportCurrentFrame() -> LivePreviewFrameExporter.Frame? {
    guard renderer != nil, let pixelBuffer = displayLayer.sampleBufferRenderer.displayedPixelBuffer() else {
      NSSound.beep()
      return nil
    }
    do {
      let frame = try frameExporter.export(pixelBuffer, to: fileStore)
      if let renderer {
        fileStore.recordExportedFrame(url: frame.url, deviceID: renderer.deviceID, size: frame.image.size)
      }
      return frame
    } catch {
      SnapOLog.ui.error("Unable to export live frame: \(error.localizedDescription, privacy: .public)")
      NSSound.beep()
      return nil
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
    let wantsMultitouch = event.modifierFlags.contains(.option) &&
      !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)
    if gestureDisplaySize != nil || (wantsMultitouch && !pointerState.isPointerDown) {
      handleMultitouch(phase, event: event)
      return
    }
    if multitouch != nil {
      multitouch = nil
      updateTouchOverlay()
    }
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
      sendPointer(.down, .touchscreen, devicePoint)

    case .drag:
      guard pointerState.isPointerDown, let devicePoint else { return }
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

  private func sendPointer(
    _ action: LivePreviewPointerAction,
    _ source: LivePreviewPointerSource,
    _ location: CGPoint
  ) {
    guard let renderer, let size = renderer.session.media?.size else { return }
    renderer.sendPointer(action, source, [location], size)
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
    var lastDeviceLocation: CGPoint?
  }
}

/// Normalized positions keep the gesture independent of the preview's scale.
struct LivePreviewMultitouch {
  private(set) var center = CGPoint(x: 0.5, y: 0.5)
  private var offset: CGPoint
  private var lastPointer: CGPoint

  init(pointer: CGPoint) {
    offset = CGPoint(x: pointer.x - 0.5, y: pointer.y - 0.5)
    lastPointer = pointer
  }

  var locations: [CGPoint] {
    [
      CGPoint(x: center.x + offset.x, y: center.y + offset.y),
      CGPoint(x: center.x - offset.x, y: center.y - offset.y)
    ]
  }

  mutating func move(to pointer: CGPoint, translating: Bool) {
    let delta = CGPoint(x: pointer.x - lastPointer.x, y: pointer.y - lastPointer.y)
    lastPointer = pointer
    if translating {
      center.x = min(1 - abs(offset.x), max(abs(offset.x), center.x + delta.x))
      center.y = min(1 - abs(offset.y), max(abs(offset.y), center.y + delta.y))
    } else {
      let limitX = min(center.x, 1 - center.x)
      let limitY = min(center.y, 1 - center.y)
      offset.x = min(limitX, max(-limitX, offset.x + delta.x))
      offset.y = min(limitY, max(-limitY, offset.y + delta.y))
    }
  }
}

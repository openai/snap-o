import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import OSLog

enum SnapOLog {
  static let storage = Logger(subsystem: "Snap-O.FrameExportTests", category: "storage")
  static let ui = Logger(subsystem: "Snap-O.FrameExportTests", category: "ui")
}

@MainActor
final class LivePreviewSession {
  let displayInfo: DisplayInfo? = DisplayInfo(size: CGSize(width: 64, height: 64), densityScale: 1)
  var sampleBufferHandler: ((CMSampleBuffer) -> Void)?
  func addRenderer(id: UUID, receive: @escaping (CMSampleBuffer) -> Void) {
    sampleBufferHandler = receive
  }

  func removeRenderer(id: UUID) {
    sampleBufferHandler = nil
  }
}

enum LivePreviewPointerAction { case down, move, up, cancel }
enum LivePreviewPointerSource { case mouse, touchscreen }

@MainActor
private final class KeyboardRecorder: LivePreviewKeyboardHandling {
  var events: [LivePreviewKeyboardEvent] = []
  var stops = 0
  var preparations = 0
  var discardedInputs = 0
  func prepare() {
    preparations += 1
  }

  func discardPendingInput() {
    discardedInputs += 1
  }

  func send(_ event: LivePreviewKeyboardEvent) {
    events.append(event)
  }

  func stop() {
    stops += 1
  }
}

/// Standalone tests have no LaunchServices activation, so provide the system focus state.
private final class KeyboardTestApplication: NSApplication {
  var testActive = true
  override var isActive: Bool {
    testActive
  }
}

private final class KeyboardTestWindow: NSWindow {
  var testKey = true
  var suppressMouseEvents = false
  override var isKeyWindow: Bool {
    testKey
  }

  override func sendEvent(_ event: NSEvent) {
    // Exercise the app's mouse monitors without opening native menus in standalone tests.
    if suppressMouseEvents, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { return }
    super.sendEvent(event)
  }
}

@main
@MainActor
struct LivePreviewFrameExportTests {
  private static let testDevice = Device(
    id: "test-device", model: "Test Device", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil
  )

  static func main() async throws {
    _ = KeyboardTestApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Snap-O-FrameExport-\(UUID().uuidString)", isDirectory: true)
    let store = FileStore(baseDir: directory)
    defer { store.purgeExistingFiles() }
    if CommandLine.arguments.contains("--frames-only") {
      hiddenPreviewRetainsLatestFrame(store: store)
      print("Frame-copy tests passed with a fake renderer and no windows")
      return
    }
    oldViewCannotDiscardRemountedKeyboardInput(store: store)
    if CommandLine.arguments.contains("--ownership-only") {
      print("Keyboard remount ownership tests passed without windows")
      return
    }
    keyboardRequiresClickAndReleasesFocus(store: store)
    keyboardClicksReleaseFocus(store: store)
    keyboardOnlySendsFromFocusedWindow(store: store)
    focusLossReleasesBothContacts(store: store)
    print("Live preview keyboard focus tests passed (click routing, two windows, focus loss and Escape)")
    if CommandLine.arguments.contains("--keyboard-only") { return }
    hiddenPreviewRetainsLatestFrame(store: store)
    print("Live preview keyboard focus, multitouch and frame-copy tests passed with a fake renderer")
  }

  private static func oldViewCannotDiscardRemountedKeyboardInput(store: FileStore) {
    let old = LivePreviewDisplayView(fileStore: store)
    let current = LivePreviewDisplayView(fileStore: store)
    let keyboard = KeyboardRecorder()
    var oldIsCurrent = true
    old.configureKeyboard(keyboard, isCurrent: { oldIsCurrent })
    oldIsCurrent = false
    current.configureKeyboard(keyboard)
    let discards = keyboard.discardedInputs
    let stops = keyboard.stops
    old.releaseKeyboardFocus()
    old.configureKeyboard(nil)
    precondition(
      keyboard.discardedInputs == discards && keyboard.stops == stops,
      "Old view teardown must not discard the current view's keyboard work"
    )
    current.releaseKeyboardFocus()
    precondition(keyboard.discardedInputs == discards + 1)
    current.configureKeyboard(nil)
    precondition(keyboard.stops == stops + 1)
  }

  private static func keyboardRequiresClickAndReleasesFocus(store: FileStore) {
    guard let app = NSApplication.shared as? KeyboardTestApplication else { fatalError("Missing test application") }
    let view = LivePreviewDisplayView(fileStore: store)
    let window = KeyboardTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = view
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    let renderer = LivePreviewRenderer(session: LivePreviewSession(), device: testDevice) { _, _, _, _ in }
    view.update(with: renderer, isVisible: true)
    let recorder = KeyboardRecorder()
    view.configureKeyboard(recorder)
    window.makeFirstResponder(view)
    view.sendKeyboard(.text("must not send"))
    precondition(recorder.events.isEmpty, "Opening a preview must not capture typing")

    func click() {
      app.sendEvent(NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 128, y: 128), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      )!)
      app.sendEvent(NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 128, y: 128), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
      )!)
    }
    func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
      )!
    }
    click()
    precondition(view.canSendKeyboardInput)
    precondition(recorder.preparations == 1, "Preview setup must prepare keyboard input")
    let stopsBeforeUpdate = recorder.stops
    view.configureKeyboard(recorder)
    precondition(view.canSendKeyboardInput && recorder.stops == stopsBeforeUpdate, "View updates must preserve typing focus")
    app.testActive = false
    precondition(!view.canSendKeyboardInput)
    app.testActive = true
    window.testKey = false
    precondition(!view.canSendKeyboardInput)
    window.testKey = true
    view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
    window.sendEvent(key(51, characters: "\u{7F}"))
    view.keyDown(with: key(123, characters: "", modifiers: .shift))
    precondition(view.performKeyEquivalent(with: key(8, characters: "c", modifiers: .command)))
    precondition(!view.performKeyEquivalent(with: key(15, characters: "r", modifiers: .command)))
    precondition(recorder.events == [.text("a"), .key(code: 67), .key(code: 21, modifiers: 1), .copy])

    view.setMarkedText(
      "compose",
      selectedRange: NSRange(location: 7, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    precondition(recorder.events.count == 4, "Uncommitted composition must remain local")
    window.sendEvent(key(53, characters: "\u{1B}"))
    precondition(!view.hasMarkedText() && recorder.events.count == 4, "Escape cancels composition before forwarding")
    window.sendEvent(key(53, characters: "\u{1B}"))
    precondition(recorder.events.last == .key(code: 111), "Escape sends Android Escape unchanged")
    precondition(recorder.events.count == 5)
    view.mouseDown(with: NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 128, y: 128), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )!)
    window.sendEvent(key(53, characters: "\u{1B}"))
    precondition(recorder.events.count == 5, "Escape cancels a pointer gesture before forwarding")
    precondition(!view.cancelGestureForEscape(), "Escape must end the pointer gesture")
    view.setMarkedText(
      "pending",
      selectedRange: NSRange(location: 7, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    window.makeFirstResponder(nil)
    precondition(!view.canSendKeyboardInput && !view.hasMarkedText())
    click()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
    precondition(!view.canSendKeyboardInput)
    click()
    view.update(with: renderer, isVisible: false)
    precondition(!view.canSendKeyboardInput)
    view.update(with: renderer, isVisible: true)
    precondition(!view.canSendKeyboardInput, "Unhiding must not rearm typing")
    click()
    precondition(recorder.stops == 0, "Focus changes must keep keyboard input connected")
    view.configureKeyboard(nil)
    precondition(!view.performKeyEquivalent(with: key(53, characters: "\u{1B}")))
    view.sendKeyboard(.text("disabled"))
    precondition(!view.canSendKeyboardInput && recorder.events.count == 5)
    view.configureKeyboard(recorder)
    precondition(!view.canSendKeyboardInput, "Enabling must require another click")
    precondition(recorder.discardedInputs > 0 && recorder.stops == 1 && recorder.preparations == 2)
  }

  private static func keyboardOnlySendsFromFocusedWindow(store: FileStore) {
    let windows = (0 ..< 2).map { _ in
      KeyboardTestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
        styleMask: [.titled], backing: .buffered, defer: false
      )
    }
    let views = windows.map { window in
      let view = LivePreviewDisplayView(fileStore: store)
      window.contentView = view
      let renderer = LivePreviewRenderer(session: LivePreviewSession(), device: testDevice) { _, _, _, _ in }
      view.update(with: renderer, isVisible: true)
      window.makeFirstResponder(view)
      return view
    }
    let recorders = [KeyboardRecorder(), KeyboardRecorder()]
    defer {
      for window in windows {
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        window.contentView = nil
      }
    }
    for index in windows.indices {
      views[index].configureKeyboard(recorders[index])
      windows[index].suppressMouseEvents = true
      NSApplication.shared.sendEvent(NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 128, y: 128), modifierFlags: [], timestamp: 0,
        windowNumber: windows[index].windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      )!)
    }
    windows[0].testKey = true
    windows[1].testKey = false
    for view in views {
      view.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    precondition(recorders[0].events == [.text("first")] && recorders[1].events.isEmpty)

    let discardedInputs = recorders.map(\.discardedInputs)
    windows[0].testKey = false
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: windows[0])
    precondition(recorders[0].discardedInputs == discardedInputs[0] + 1 && recorders[1].discardedInputs == discardedInputs[1])
    precondition(!views[0].keyboardArmed, "Losing the key window must release keyboard focus")
    windows[1].testKey = true
    for view in views {
      view.sendKeyboard(.key(code: 111))
    }
    precondition(recorders[0].events == [.text("first")] && recorders[1].events == [.key(code: 111)])
  }

  private static func keyboardClicksReleaseFocus(store: FileStore) {
    let window = KeyboardTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = LivePreviewDisplayView(fileStore: store)
    window.contentView = view
    window.suppressMouseEvents = true
    defer {
      window.makeFirstResponder(nil)
      window.orderOut(nil)
      window.contentView = nil
    }
    let renderer = LivePreviewRenderer(session: LivePreviewSession(), device: testDevice) { _, _, _, _ in }
    view.update(with: renderer, isVisible: true)
    let recorder = KeyboardRecorder()
    view.configureKeyboard(recorder)
    window.makeFirstResponder(view)

    func mouse(_ type: NSEvent.EventType, x: CGFloat, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: view.convert(NSPoint(x: x, y: 100), to: nil), modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      )!
    }
    let imageClick = mouse(.leftMouseDown, x: 160)
    let releases = [
      mouse(.leftMouseDown, x: 20),
      mouse(.rightMouseDown, x: 20),
      mouse(.leftMouseDown, x: 20, modifiers: .control),
      mouse(.rightMouseDown, x: 160),
      mouse(.leftMouseDown, x: 160, modifiers: .control),
      mouse(.leftMouseDown, x: 160, modifiers: .command),
      mouse(.otherMouseDown, x: 160),
      mouse(.leftMouseDown, x: -10)
    ]
    for event in releases {
      NSApplication.shared.sendEvent(imageClick)
      precondition(view.canSendKeyboardInput)
      view.setMarkedText(
        "pending",
        selectedRange: NSRange(location: 7, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
      )
      let discardedInputs = recorder.discardedInputs
      NSApplication.shared.sendEvent(event)
      precondition(!view.canSendKeyboardInput && !view.hasMarkedText())
      precondition(recorder.discardedInputs == discardedInputs + 1, "Every click that ends typing must discard queued input")
      view.insertText("must not send", replacementRange: NSRange(location: NSNotFound, length: 0))
      precondition(recorder.events.isEmpty)
    }
    let container = NSView(frame: view.frame)
    window.contentView = container
    container.addSubview(view)
    let overlay = NSView(frame: NSRect(x: 120, y: 80, width: 80, height: 40))
    container.addSubview(overlay)
    window.makeFirstResponder(view)
    NSApplication.shared.sendEvent(imageClick)
    precondition(!view.canSendKeyboardInput, "Controls covering the device image must not activate typing")
    overlay.removeFromSuperview()
    NSApplication.shared.sendEvent(imageClick)
    precondition(view.canSendKeyboardInput)
    _ = view.menu(for: mouse(.rightMouseDown, x: 160))
    precondition(!view.canSendKeyboardInput, "Opening a context menu directly must also release focus")
  }

  private static func focusLossReleasesBothContacts(store: FileStore) {
    _ = NSApplication.shared
    let view = LivePreviewDisplayView(fileStore: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = view
    defer { window.contentView = nil }
    var cancelledContacts: [CGPoint] = []
    let renderer = LivePreviewRenderer(session: LivePreviewSession(), device: testDevice) { action, _, points, _ in
      if action == .cancel { cancelledContacts = points }
    }
    view.update(with: renderer, isVisible: true)
    view.mouseDown(with: NSEvent.mouseEvent(
      with: .leftMouseDown, location: view.convert(CGPoint(x: 160, y: 128), to: nil), modifierFlags: [.option],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )!)

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

    precondition(cancelledContacts == [CGPoint(x: 40, y: 32), CGPoint(x: 24, y: 32)])
  }

  private static func hiddenPreviewRetainsLatestFrame(store: FileStore) {
    var latest: CVPixelBuffer?
    let output = LivePreviewFrameOutput(
      enqueue: { latest = CMSampleBufferGetImageBuffer($0) }, currentFrame: { latest }, flush: { latest = nil }
    )
    let image = NSImage(size: CGSize(width: 64, height: 64))
    var encodedFrame: CVPixelBuffer?
    let exporter = LivePreviewFrameExporter { frame in
      encodedFrame = frame
      return (image, Data("encoded image".utf8))
    }
    let view = LivePreviewDisplayView(fileStore: store, frameOutput: output, frameExporter: exporter)
    let session = LivePreviewSession()
    let renderer = LivePreviewRenderer(session: session, device: testDevice) { _, _, _, _ in }
    view.update(with: renderer, isVisible: true)
    let samples = makeRawSamples()
    session.sampleBufferHandler?(samples[0])
    precondition(latest != nil)
    view.update(with: renderer, isVisible: false)
    precondition(session.sampleBufferHandler != nil, "Hiding must retain the session subscription")
    session.sampleBufferHandler?(samples[1])
    let hiddenFrame = latest
    view.update(with: renderer, isVisible: true)
    precondition(latest === hiddenFrame, "Showing must not flush the latest frame")
    var copiedImage: NSImage?
    var copies = 0
    view.imageCopied = { copies += 1 }
    view.copyFrame { copiedImage = $0
      return true
    }
    precondition(copies == 1 && copiedImage === image && encodedFrame === hiddenFrame)
    session.sampleBufferHandler?(samples[2])
    precondition(copies == 1 && encodedFrame === hiddenFrame, "New frames must not rewrite an earlier copy")
    view.update(with: nil)
    precondition(session.sampleBufferHandler == nil && latest == nil)
    view.copyFrame { _ in preconditionFailure("A detached preview cannot write an image") }
    precondition(copies == 1)
  }

  private static func makeRawSamples() -> [CMSampleBuffer] {
    let builder = EmulatorPreviewFrameBuilder()
    return (0 ..< 3).map { index in
      let pixel: [UInt8] = index == 1 ? [0, 0, 255, 255] : [255, 0, 0, 255]
      let rgba = Data((0 ..< 64 * 64).flatMap { _ in pixel })
      return try! builder.makeSample(rgba: rgba, width: 64, height: 64, timestamp: UInt64(index) * 33333)!
    }
  }
}

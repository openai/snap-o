import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

enum MediaSaveKind {
  case image
  case video
  var fileExtension: String {
    "png"
  }
}

enum SnapOLog {
  static let storage = Logger(subsystem: "Snap-O.FrameExportTests", category: "storage")
  static let ui = Logger(subsystem: "Snap-O.FrameExportTests", category: "ui")
}

struct LivePreviewOperationHandle {
  let deviceID = "test-device"
  let session: LivePreviewSession
}

@MainActor
final class LivePreviewSession {
  struct Media { let size: CGSize }
  let media: Media? = Media(size: CGSize(width: 64, height: 64))
  var sampleBufferHandler: ((CMSampleBuffer) -> Void)?
}

enum LivePreviewPointerAction { case down, move, up, cancel }
enum LivePreviewPointerSource { case mouse, touchscreen }

@MainActor
private final class KeyboardRecorder: LivePreviewKeyboardHandling {
  var events: [LivePreviewKeyboardEvent] = []
  var stops = 0
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
  override var isKeyWindow: Bool {
    testKey
  }
}

private final class EncodedSamples: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CMSampleBuffer] = []

  var samples: [CMSampleBuffer] {
    lock.withLock { storage }
  }

  func append(_ sample: CMSampleBuffer) {
    lock.withLock { storage.append(sample) }
  }
}

@main
@MainActor
struct LivePreviewFrameExportTests {
  static func main() throws {
    _ = KeyboardTestApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Snap-O-FrameExport-\(UUID().uuidString)", isDirectory: true)
    let store = FileStore(baseDir: directory)
    defer { store.purgeExistingFiles() }
    keyboardRequiresClickAndReleasesFocus(store: store)
    keyboardOnlySendsFromFocusedWindow(store: store)
    focusLossReleasesBothContacts(store: store)
    print("Live preview keyboard focus tests passed (two windows, focus loss and Escape)")
    if CommandLine.arguments.contains("--keyboard-only") { return }
    hiddenPreviewRetainsLatestFrame(store: store, raw: false)
    hiddenPreviewRetainsLatestFrame(store: store, raw: true)
    print("Live preview keyboard focus, multitouch, hidden rendering and copy tests passed (H.264 and raw frames)")
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
    let renderer = LivePreviewRenderer(operation: LivePreviewOperationHandle(session: LivePreviewSession())) { _, _, _, _ in }
    view.update(with: renderer, isVisible: true)
    let recorder = KeyboardRecorder()
    view.configureKeyboard(recorder, enabled: true)
    window.makeFirstResponder(view)
    view.sendKeyboard(.text("must not send"))
    precondition(recorder.events.isEmpty, "Opening a preview must not capture typing")

    func click() {
      view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 128, y: 128), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      )!)
      view.mouseUp(with: NSEvent.mouseEvent(
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
    view.configureKeyboard(recorder, enabled: false)
    precondition(!view.performKeyEquivalent(with: key(53, characters: "\u{1B}")))
    view.sendKeyboard(.text("disabled"))
    precondition(!view.canSendKeyboardInput && recorder.events.count == 5)
    view.configureKeyboard(recorder, enabled: true)
    precondition(!view.canSendKeyboardInput, "Enabling must require another click")
    precondition(recorder.stops > 0)
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
      let renderer = LivePreviewRenderer(operation: LivePreviewOperationHandle(session: LivePreviewSession())) { _, _, _, _ in }
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
      views[index].configureKeyboard(recorders[index], enabled: true)
      views[index].keyboardArmed = true
    }
    windows[0].testKey = true
    windows[1].testKey = false
    for view in views {
      view.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    precondition(recorders[0].events == [.text("first")] && recorders[1].events.isEmpty)

    let stops = recorders.map(\.stops)
    windows[0].testKey = false
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: windows[0])
    precondition(recorders[0].stops == stops[0] + 1 && recorders[1].stops == stops[1])
    precondition(!views[0].keyboardArmed, "Losing the key window must release keyboard focus")
    windows[1].testKey = true
    for view in views {
      view.sendKeyboard(.key(code: 111))
    }
    precondition(recorders[0].events == [.text("first")] && recorders[1].events == [.key(code: 111)])
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
    let renderer = LivePreviewRenderer(operation: LivePreviewOperationHandle(session: LivePreviewSession())) { action, _, points, _ in
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

  private static func hiddenPreviewRetainsLatestFrame(store: FileStore, raw: Bool) {
    _ = NSApplication.shared
    let view = LivePreviewDisplayView(fileStore: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    guard let layer = view.layer?.sublayers?.first as? AVSampleBufferDisplayLayer else {
      fatalError("Missing video layer")
    }
    // Pixel-buffer inspection requires a paused renderer; advance its clock per test frame.
    var timebase: CMTimebase?
    precondition(CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase
    ) == noErr)
    guard let timebase else { fatalError("Missing timebase") }
    layer.controlTimebase = timebase
    let session = LivePreviewSession()
    let renderer = LivePreviewRenderer(operation: LivePreviewOperationHandle(session: session)) { _, _, _, _ in }
    view.update(with: renderer, isVisible: true)
    var copyFeedbackCount = 0
    view.imageCopied = { copyFeedbackCount += 1 }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Keep clipboard when no frame is available", forType: .string)
    view.copyFrame(to: pasteboard)
    precondition(pasteboard.string(forType: .string) == "Keep clipboard when no frame is available")
    precondition(!view.validateMenuItem(NSMenuItem()))
    precondition(copyFeedbackCount == 0, "No frame must not report a successful copy")
    let samples = raw ? makeRawSamples() : makeEncodedSamples()
    let imageContext = CIContext()
    func displays(red: Bool) -> Bool {
      precondition(layer.sampleBufferRenderer.status != .failed, "Renderer failed: \(String(describing: layer.sampleBufferRenderer.error))")
      guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer(),
            let image = imageContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: 64, height: 64)),
            let color = NSBitmapImageRep(cgImage: image).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB)
      else { return false }
      return red ? color.redComponent > 0.8 : color.blueComponent > 0.8
    }
    func copyAndCheck(red: Bool) {
      precondition(view.validateMenuItem(NSMenuItem()))
      view.copyFrame(to: pasteboard)
      guard let data = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: data),
            let color = bitmap.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB)
      else { fatalError("Copy must write an image to the clipboard") }
      precondition(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
      precondition(red ? color.redComponent > 0.8 : color.blueComponent > 0.8, "Copy must use the displayed frame")
    }

    session.sampleBufferHandler?(samples[0])
    eventually("Initial frame must decode") { displays(red: true) }
    copyAndCheck(red: true)
    precondition(copyFeedbackCount == 1, "Successful copy must report feedback once")
    let firstCopy = pasteboard.data(forType: .tiff)
    view.update(with: renderer, isVisible: false)
    precondition(layer.isHidden && session.sampleBufferHandler != nil)
    CMTimebaseSetTime(timebase, time: CMSampleBufferGetPresentationTimeStamp(samples[1]))
    session.sampleBufferHandler?(samples[1])
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))

    view.update(with: renderer, isVisible: true)
    precondition(!layer.isHidden)
    eventually("Uncover must show the latest frame without waiting for new video") { displays(red: false) }
    precondition(pasteboard.data(forType: .tiff) == firstCopy, "Playback must not change a previously copied image")
    copyAndCheck(red: false)
    precondition(copyFeedbackCount == 2, "Repeated copies must each report feedback")
    CMTimebaseSetTime(timebase, time: CMSampleBufferGetPresentationTimeStamp(samples[2]))
    session.sampleBufferHandler?(samples[2])
    eventually("Decoding must continue after uncover without a new keyframe") { displays(red: true) }
    precondition(!layer.sampleBufferRenderer.requiresFlushToResumeDecoding)
    view.update(with: nil)
    precondition(session.sampleBufferHandler == nil, "Detaching must release the session callback")
    precondition(!view.validateMenuItem(NSMenuItem()))
    let lastCopy = pasteboard.data(forType: .tiff)
    view.copyFrame(to: pasteboard)
    precondition(pasteboard.data(forType: .tiff) == lastCopy, "A detached preview must leave the clipboard alone")
    precondition(copyFeedbackCount == 2, "A detached preview must not report a successful copy")
    window.contentView = nil
  }

  private static func makeRawSamples() -> [CMSampleBuffer] {
    let builder = EmulatorPreviewFrameBuilder()
    return (0 ..< 3).map { index in
      let pixel: [UInt8] = index == 1 ? [0, 0, 255, 255] : [255, 0, 0, 255]
      let rgba = Data((0 ..< 64 * 64).flatMap { _ in pixel })
      return try! builder.makeSample(rgba: rgba, width: 64, height: 64, timestamp: UInt64(index) * 33333)!
    }
  }

  private static func makeEncodedSamples() -> [CMSampleBuffer] {
    var compressionSession: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault, width: 64, height: 64, codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &compressionSession
    )
    guard status == noErr, let compressionSession else { fatalError("Could not create H.264 encoder: \(status)") }
    defer { VTCompressionSessionInvalidate(compressionSession) }
    precondition(VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) ==
      noErr)
    precondition(VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber) ==
      noErr)
    let output = EncodedSamples()
    for index in 0 ..< 3 {
      let buffer = makeBuffer(width: 64, height: 64)
      fill(buffer, red: index == 1 ? 0 : 255, blue: index == 1 ? 255 : 0)
      let result = VTCompressionSessionEncodeFrame(
        compressionSession, imageBuffer: buffer,
        presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30), frameProperties: nil, infoFlagsOut: nil
      ) { status, _, sample in
        precondition(status == noErr)
        if let sample { output.append(sample) }
      }
      precondition(result == noErr)
    }
    precondition(VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid) == noErr)
    let samples = output.samples
    precondition(samples.count == 3)
    for sample in samples.dropFirst() {
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
      precondition(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true, "Resume test needs dependent frames")
    }
    return samples
  }

  private static func eventually(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(condition(), message)
  }

  private static func makeBuffer(width: Int = 16, height: Int = 24) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result
    )
    guard status == kCVReturnSuccess, let result else { fatalError("Could not create pixel buffer") }
    return result
  }

  private static func fill(_ buffer: CVPixelBuffer, red: UInt8, blue: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
      fatalError("Pixel buffer has no storage")
    }
    for y in 0 ..< CVPixelBufferGetHeight(buffer) {
      for x in 0 ..< CVPixelBufferGetWidth(buffer) {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        base[offset] = blue
        base[offset + 1] = 0
        base[offset + 2] = red
        base[offset + 3] = 255
      }
    }
  }
}

import AppKit
@preconcurrency import AVFoundation
import DependenciesTestSupport
import Observation
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized, .dependency(\.continuousClock, ContinuousClock()))
@MainActor
struct CaptureReviewEscapeTests {
  @Test(arguments: ["Keep Editing", "Escape", "Return", "Enter", "Discard"])
  func discardConfirmationUsesExpectedAction(response: String) async throws {
    let fixture = try await makeReview()
    defer { fixture.close() }
    try fixture.window.sendEvent(key(53, in: fixture.window))
    try await waitForUI(until: { fixture.window.attachedSheet != nil })
    let sheet = try #require(fixture.window.attachedSheet)
    #expect(FileManager.default.fileExists(atPath: fixture.captureURL.path))

    let keyCodes: [String: UInt16] = ["Escape": 53, "Return": 36, "Enter": 76]
    if let keyCode = keyCodes[response] {
      try sheet.sendEvent(key(keyCode, in: sheet))
    } else {
      let actionButton = try #require(button(in: sheet, named: response))
      _ = actionButton.accessibilityPerformPress?()
    }
    try await waitForUI(until: { fixture.window.attachedSheet == nil })
    #expect(fixture.window.attachedSheet == nil)
    let keepsCapture = response == "Keep Editing" || response == "Escape"
    if !keepsCapture { await fixture.controller.cleanup?.value }
    #expect(FileManager.default.fileExists(atPath: fixture.captureURL.path) == keepsCapture)
    if keepsCapture {
      try fixture.window.sendEvent(key(53, in: fixture.window))
      try await waitForUI(until: { fixture.window.attachedSheet != nil })
      #expect(fixture.window.attachedSheet != nil)
    }
  }

  @Test(arguments: [false, true])
  func escapeWorksAfterReturningFromLivePreview(cropImage: Bool) async throws {
    let fixture = try await makeReview()
    defer { fixture.close() }
    let image = try Data(contentsOf: fixture.captureURL)

    for captureNumber in 1 ... 3 {
      if cropImage {
        fixture.controller.review.setCrop(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), for: try #require(fixture.controller.review.selectedItemID))
        try await Task.sleep(for: .milliseconds(50))
      }
      try fixture.window.sendEvent(key(53, in: fixture.window))
      try await waitForUI(until: { fixture.window.attachedSheet != nil })
      let sheet = try #require(fixture.window.attachedSheet, "Escape must open the alert for capture \(captureNumber)")
      try sheet.sendEvent(key(36, in: sheet))
      await fixture.controller.cleanup?.value
      #expect(!FileManager.default.fileExists(atPath: fixture.captureURL.path))

      guard captureNumber < 3 else { break }
      fixture.showsReview.value = false
      fixture.window.contentView?.layoutSubtreeIfNeeded()
      try await waitForUI(until: { fixture.window.attachedSheet == nil })
      try await Task.sleep(for: .milliseconds(50))

      try image.write(to: fixture.captureURL)
      let next = CaptureMedia(device: fixture.capture.device, media: fixture.capture.media)
      fixture.controller.show(next)
      fixture.showsReview.value = true
      fixture.window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test(arguments: [false, true])
  func escapeWorksWhileNativeVideoHasFocus(isTrimming: Bool) async throws {
    let fixture = try await makeReview()
    defer { fixture.close() }
    let url = fixture.root.appendingPathComponent("recording.mp4")
    try await makeVideo(at: url)
    let video = CaptureMedia(
      device: fixture.capture.device,
      media: .video(
        url: url, capturedAt: .now, display: fixture.capture.media.common.display
      )
    )
    fixture.controller.show(video)
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    try #require(fixture.window.attachedSheet == nil)
    if isTrimming {
      try await waitForUI(until: { button(in: fixture.window, named: "Trim Recording")?.isAccessibilityEnabled?() == true })
      let trim = try #require(button(in: fixture.window, named: "Trim Recording"))
      #expect(trim.accessibilityPerformPress?() == true)
      try await waitForUI(until: { button(in: fixture.window, named: "Cancel Trim") != nil })
      try #require(button(in: fixture.window, named: "Cancel Trim") != nil)
    }
    let player = try #require(videoPlayer(in: fixture.window.contentView))
    player.focusPlayer()
    let responder = try #require(fixture.window.firstResponder as? NSView)
    #expect(responder === player || responder.isDescendant(of: player))

    try fixture.window.sendEvent(key(53, in: fixture.window))

    if isTrimming {
      try await waitForUI(until: { button(in: fixture.window, named: "Trim Recording") != nil })
      try #require(button(in: fixture.window, named: "Trim Recording") != nil)
      #expect(fixture.window.attachedSheet == nil)
      #expect(FileManager.default.fileExists(atPath: url.path))
      try fixture.window.sendEvent(key(53, in: fixture.window))
    }
    try await waitForUI(until: { fixture.window.attachedSheet != nil })
    let sheet = try #require(fixture.window.attachedSheet)
    #expect(button(in: sheet, named: "Discard") != nil)
    #expect(button(in: sheet, named: "Keep Editing") != nil)
  }

  @Test
  func escapeDismissesTheSaveSheetWithoutDiscarding() async throws {
    let fixture = try await makeReview()
    defer { fixture.close() }
    let save = try #require(button(in: fixture.window, named: "Save Screenshot to History"))
    #expect(save.accessibilityPerformPress?() == true)
    try await waitForUI(until: { fixture.window.attachedSheet != nil })
    let sheet = try #require(fixture.window.attachedSheet)

    try sheet.sendEvent(key(53, in: sheet))

    try await waitForUI(until: { fixture.window.attachedSheet == nil })
    try await Task.sleep(for: .milliseconds(50))
    #expect(fixture.window.attachedSheet == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.captureURL.path))
  }

  @Test
  func closeButtonStillDiscardsImmediately() async throws {
    let fixture = try await makeReview()
    defer { fixture.close() }
    let close = try #require(button(in: fixture.window, named: "Discard Screenshot"))
    #expect(close.accessibilityPerformPress?() == true)
    #expect(fixture.window.attachedSheet == nil)
    await fixture.controller.cleanup?.value
    #expect(!FileManager.default.fileExists(atPath: fixture.captureURL.path))
  }

  @MainActor
  private struct ReviewFixture {
    let window: NSWindow
    let captureURL: URL
    let root: URL
    let controller: ReviewPresentation
    let capture: CaptureMedia
    let showsReview: TestValue<Bool>

    func close() {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.orderOut(nil)
      window.contentView = nil
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeReview() async throws -> ReviewFixture {
    NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let drafts = root.appendingPathComponent("drafts")
    let store = FileStore(baseDir: drafts)
    let url = drafts.appendingPathComponent("capture.png")
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    let context = try #require(CGContext(
      data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 400,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(NSColor.blue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
    let bitmap = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    let capture = CaptureMedia(
      device: Device(id: "test-phone", model: "Phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: .image(url: url, capturedAt: .now, display: DisplayInfo(size: CGSize(width: 100, height: 200), densityScale: 1))
    )
    let history = CaptureHistory(repository: CaptureHistoryRepository(root: root.appendingPathComponent("history")))
    let showsReview = TestValue(true)
    let controller = ReviewPresentation(capture: capture, store: store, history: history, showsReview: showsReview)
    let view = NSHostingView(rootView: ReviewContent(controller: controller, showsReview: showsReview).environment(history))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(50))
    return ReviewFixture(
      window: window, captureURL: url, root: root, controller: controller, capture: capture, showsReview: showsReview
    )
  }

  @Observable
  @MainActor
  fileprivate final class ReviewPresentation {
    var review: CaptureReviewState
    let store: FileStore
    let history: CaptureHistory
    let showsReview: TestValue<Bool>
    var cleanup: Task<Void, Never>?

    init(capture: CaptureMedia, store: FileStore, history: CaptureHistory, showsReview: TestValue<Bool>) {
      self.store = store
      self.history = history
      self.showsReview = showsReview
      review = CaptureReviewState(
        batch: ReadyCaptureBatch([capture], fileStore: store), selectedDeviceID: capture.device.id,
        fileStore: store, history: history
      )
    }

    func show(_ capture: CaptureMedia) {
      let previous = review
      cleanup = Task { await previous.close() }
      review = CaptureReviewState(
        batch: ReadyCaptureBatch([capture], fileStore: store), selectedDeviceID: capture.device.id,
        fileStore: store, history: history
      )
    }

    func dismiss() {
      showsReview.value = false
      let previous = review
      cleanup = Task { await previous.close() }
    }
  }

  private struct ReviewContent: View {
    let controller: ReviewPresentation
    @Bindable var showsReview: TestValue<Bool>

    var body: some View {
      if showsReview.value {
        CaptureReviewView(review: controller.review) { controller.dismiss() }
          .id(controller.review.batch.id)
      } else {
        Text("Live Preview").focusable()
      }
    }
  }

  private func makeVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
      AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
    ])
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let buffer = try CVMutablePixelBuffer(.init(
      pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB), size: .init(width: 32, height: 32)
    ))
    buffer.withUnsafeBuffer { pixel in
      CVPixelBufferLockBaseAddress(pixel, [])
      memset(CVPixelBufferGetBaseAddress(pixel), 80, CVPixelBufferGetDataSize(pixel))
      CVPixelBufferUnlockBaseAddress(pixel, [])
    }
    let pixels = CVReadOnlyPixelBuffer(buffer)
    for frame in 0 ..< 3 {
      try await receiver.append(pixels, with: CMTime(value: Int64(frame), timescale: 10))
    }
    receiver.finish()
    await writer.finishWriting()
    try #require(writer.status == .completed)
  }

  private func videoPlayer(in view: NSView?) -> CaptureVideoPlayer.PlayerView? {
    if let player = view as? CaptureVideoPlayer.PlayerView { return player }
    for child in view?.subviews ?? [] {
      if let player = videoPlayer(in: child) { return player }
    }
    return nil
  }

  private func button(in element: AnyObject, named name: String) -> AnyObject? {
    if element.accessibilityRole?() == NSAccessibility.Role.button,
       element.accessibilityLabel?() == name || element.accessibilityTitle?() == name { return element }
    for child in element.accessibilityChildren?() ?? [] {
      if let found = button(in: child as AnyObject, named: name) { return found }
    }
    return nil
  }

  private func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
    let character = switch code {
    case 53: "\u{1B}"
    case 76: "\u{3}"
    default: "\r"
    }
    return try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: character,
      charactersIgnoringModifiers: character, isARepeat: false, keyCode: code
    ))
  }

  private func waitForUI(
    until condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), "UI condition did not become true before the deadline", sourceLocation: sourceLocation)
  }
}

import AppKit
@preconcurrency import AVFoundation
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct LivePreviewThumbnailTests {
  @Test(arguments: [CGSize(width: 320, height: 640), CGSize(width: 640, height: 320)])
  func refreshDownsamplesAndKeepsTheCachedImageOnFailure(size: CGSize) async throws {
    let thumbnail = LivePreviewThumbnail()
    let png = try makePNG(size: size)
    await thumbnail.refresh(pixelSize: CGSize(width: 96, height: 160)) { png }
    let cached = try #require(thumbnail.image)
    let expectedHeight = max(160, 96 * size.height / size.width)
    #expect(cached.width == Int(expectedHeight * size.width / size.height) && cached.height == Int(expectedHeight))

    await thumbnail.refresh(pixelSize: CGSize(width: 96, height: 160)) {
      #expect(thumbnail.isLoading)
      #expect(thumbnail.image === cached)
      return Data("invalid image".utf8)
    }
    #expect(thumbnail.image === cached)
    #expect(thumbnail.hasFailed)
    #expect(!thumbnail.isLoading)
  }

  @Test
  func cancelledAndSupersededRefreshesCannotReplaceTheImage() async throws {
    let thumbnail = LivePreviewThumbnail()
    let png = try makePNG()
    let pending = TestValue<CheckedContinuation<Data, Never>?>(nil)
    let stale = Task {
      await thumbnail.refresh(pixelSize: CGSize(width: 192, height: 320)) {
        await withCheckedContinuation { pending.value = $0 }
      }
    }
    try await waitForState { pending.value != nil }
    await thumbnail.refresh(pixelSize: CGSize(width: 96, height: 160)) { png }
    let fresh = try #require(thumbnail.image)
    pending.value?.resume(returning: png)
    await stale.value
    #expect(thumbnail.image === fresh)

    pending.value = nil
    let cancelled = Task {
      await thumbnail.refresh(pixelSize: CGSize(width: 192, height: 320)) {
        await withCheckedContinuation { pending.value = $0 }
      }
    }
    try await waitForState { pending.value != nil }
    cancelled.cancel()
    pending.value?.resume(returning: png)
    await cancelled.value
    #expect(thumbnail.image === fresh)
    #expect(!thumbnail.hasFailed)
    #expect(!thumbnail.isLoading)
  }

  @Test
  func refreshPolicyRunsOncePerAppearanceAndSkipsTheSelectedDevice() async throws {
    let thumbnail = LivePreviewThumbnail()
    let png = try makePNG()
    var requests = 0
    let selected = LivePreviewThumbnailRefresh()
    for isSelected in [true, false, true] {
      await selected.run(thumbnail: thumbnail, isSelected: isSelected, pixelSize: CGSize(width: 40, height: 80)) {
        requests += 1
        return png
      }
    }
    #expect(requests == 0)
    let other = LivePreviewThumbnailRefresh()
    for isSelected in [false, true, false] {
      await other.run(thumbnail: thumbnail, isSelected: isSelected, pixelSize: CGSize(width: 80, height: 160)) {
        requests += 1
        return png
      }
    }
    #expect(requests == 1)
    #expect(thumbnail.pixelSize == CGSize(width: 80, height: 160))
    let cached = try #require(thumbnail.image)
    let nextAppearance = LivePreviewThumbnailRefresh()
    let entered = AsyncStream<Void>.makeStream()
    let task = Task {
      await nextAppearance.run(thumbnail: thumbnail, isSelected: false, pixelSize: CGSize(width: 80, height: 160)) {
        requests += 1
        entered.continuation.yield(())
        try await suspendUntilCancelled(.zero)
        return png
      }
    }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(requests == 2)
    #expect(thumbnail.image === cached)
    task.cancel()
    await task.value
    #expect(thumbnail.image === cached)
    #expect(!thumbnail.isLoading)
    #expect(!thumbnail.hasFailed)
  }

  @Test
  func mirrorCachesItsLastFrameWithoutAllowingAnOlderScreenshotToReplaceIt() async throws {
    let source = AVSampleBufferDisplayLayer()
    let thumbnail = LivePreviewThumbnail()
    thumbnail.videoRenderer = source.sampleBufferRenderer
    let view = LivePreviewThumbnailDisplayView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
    view.thumbnail = thumbnail
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 160, height: 80),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let content = NSView(frame: window.contentLayoutRect)
    content.wantsLayer = true
    source.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
    content.layer?.addSublayer(source)
    view.setFrameOrigin(CGPoint(x: 80, y: 0))
    content.addSubview(view)
    window.contentView = content
    window.orderFront(nil)
    defer {
      view.stop()
      window.orderOut(nil)
      window.contentView = nil
    }
    let output = try #require(view.layer?.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
    let pendingScreenshot = TestValue<CheckedContinuation<Data, Never>?>(nil)
    let refresh = Task {
      await thumbnail.refresh(pixelSize: CGSize(width: 80, height: 80)) {
        await withCheckedContinuation { pendingScreenshot.value = $0 }
      }
    }
    try await waitForState { pendingScreenshot.value != nil }
    for (width, height) in [(32, 64), (64, 32)] {
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer
      )
      #expect(status == kCVReturnSuccess)
      let buffer = try #require(pixelBuffer)
      let sample = try #require(LivePreviewThumbnailDisplayView.sampleBuffer(for: buffer))
      #expect(CMSampleBufferGetImageBuffer(sample) === buffer)
      source.sampleBufferRenderer.enqueue(sample)
      try await eventually {
        guard let displayed = output.sampleBufferRenderer.displayedPixelBuffer() else { return false }
        return CVPixelBufferGetWidth(displayed) == width && CVPixelBufferGetHeight(displayed) == height
      }
    }
    view.stop()
    #expect(view.thumbnail == nil)
    #expect(thumbnail.videoRenderer === source.sampleBufferRenderer)
    let cached = try #require(thumbnail.image)
    #expect(cached.width == 64 && cached.height == 32)
    #expect(!thumbnail.isLoading)
    source.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    thumbnail.videoRenderer = nil
    try pendingScreenshot.value?.resume(returning: makePNG())
    await refresh.value
    #expect(thumbnail.image === cached)
  }

  private func makePNG(size: CGSize = CGSize(width: 320, height: 640)) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }
}

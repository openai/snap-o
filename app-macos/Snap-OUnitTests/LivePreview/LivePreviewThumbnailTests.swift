import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import Testing

@MainActor
struct LivePreviewThumbnailTests {
  @Test
  func refreshKeepsTheCachedImageOnFailure() async throws {
    let thumbnail = try makeThumbnail()
    let png = Data([1])
    await thumbnail.refresh(pixelSize: CGSize(width: 96, height: 160)) { png }
    let cached = try #require(thumbnail.image)
    #expect(thumbnail.lastPreviewFrame == nil, "A sidebar screenshot is not a frame from this preview")

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
    let thumbnail = try makeThumbnail()
    let png = Data([1])
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
    let thumbnail = try makeThumbnail()
    let png = Data([1])
    var requests = 0
    let selected = LivePreviewThumbnailRefresh()
    for isSelected in [true, true] {
      await selected.run(thumbnail: thumbnail, isSelected: isSelected, pixelSize: CGSize(width: 40, height: 80)) {
        requests += 1
        return png
      }
    }
    #expect(requests == 0)
    for isSelected in [false, true, false] {
      await selected.run(thumbnail: thumbnail, isSelected: isSelected, pixelSize: CGSize(width: 40, height: 80)) {
        requests += 1
        return png
      }
    }
    #expect(requests == 1, "After selection moves, the old device needs one static thumbnail")
    let other = LivePreviewThumbnailRefresh()
    for isSelected in [false, true, false] {
      await other.run(thumbnail: thumbnail, isSelected: isSelected, pixelSize: CGSize(width: 80, height: 160)) {
        requests += 1
        return png
      }
    }
    #expect(requests == 2)
    #expect(thumbnail.pixelSize == CGSize(width: 80, height: 160))
    let cached = try #require(thumbnail.image)
    let nextAppearance = LivePreviewThumbnailRefresh()
    let entered = AsyncStream<Void>.makeStream()
    let task = Task {
      await nextAppearance.run(thumbnail: thumbnail, isSelected: false, pixelSize: CGSize(width: 80, height: 160)) {
        requests += 1
        entered.continuation.yield(())
        try await suspendUntilCancelled()
        return png
      }
    }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(requests == 3)
    #expect(thumbnail.image === cached)
    task.cancel()
    await task.value
    #expect(thumbnail.image === cached)
    #expect(!thumbnail.isLoading)
    #expect(!thumbnail.hasFailed)
  }

  @Test
  func cachedLiveFramePreventsAnOlderScreenshotFromReplacingIt() async throws {
    let thumbnail = try makeThumbnail()
    let pending = TestValue<CheckedContinuation<Data, Never>?>(nil)
    let refresh = Task {
      await thumbnail.refresh(pixelSize: CGSize(width: 80, height: 80)) {
        await withCheckedContinuation { pending.value = $0 }
      }
    }
    try await waitForState { pending.value != nil }
    try thumbnail.cacheLiveFrame(makePixelBuffer(width: 64, height: 32))
    let cached = try #require(thumbnail.image)
    #expect(thumbnail.lastPreviewFrame === cached)
    let oldSession = UUID()
    let resumedSession = UUID()
    thumbnail.didDisplayFrame(in: oldSession)
    #expect(thumbnail.displayedSessionID != resumedSession)
    thumbnail.didDisplayFrame(in: resumedSession)
    #expect(thumbnail.displayedSessionID == resumedSession)
    try pending.value?.resume(returning: Data([1]))
    await refresh.value
    #expect(thumbnail.image === cached)
  }

  @Test(arguments: [0.0, 0.5, 1.0])
  func reconnectIndicatorUsesTheBrightnessBehindTheAperture(center: CGFloat) throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: 96, height: 160, bitsPerComponent: 8, bytesPerRow: 384,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(gray: center < 0.5 ? 1 : 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 96, height: 160))
    context.setFillColor(red: center, green: center, blue: center, alpha: 1)
    context.fill(CGRect(x: 40, y: 72, width: 16, height: 16))
    let image = try #require(context.makeImage())
    let thumbnail = LivePreviewThumbnail(snapshotImage: { _, _ in nil }, frameImage: { _, _ in image })
    try thumbnail.cacheLiveFrame(makePixelBuffer(width: 96, height: 160))
    #expect(thumbnail.lastPreviewFrameHasLightCenter == (center >= 0.5))
  }

  @Test
  func imageSizingFillsTheThumbnailWithoutUpscalingFrames() {
    let target = CGSize(width: 96, height: 160)
    #expect(LivePreviewThumbnail.snapshotPixelLimit(source: CGSize(width: 320, height: 640), orientation: 1, target: target) == 192)
    #expect(LivePreviewThumbnail.snapshotPixelLimit(source: CGSize(width: 640, height: 320), orientation: 1, target: target) == 320)
    #expect(LivePreviewThumbnail.snapshotPixelLimit(source: CGSize(width: 640, height: 320), orientation: 6, target: target) == 192)
    #expect(LivePreviewThumbnail.frameScale(source: CGSize(width: 320, height: 160), target: CGSize(width: 80, height: 80)) == 0.5)
    #expect(LivePreviewThumbnail.frameScale(source: CGSize(width: 40, height: 40), target: target) == 1)
  }

  private func makeThumbnail() throws -> LivePreviewThumbnail {
    let image = try #require(CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage())
    return LivePreviewThumbnail(snapshotImage: { data, _ in data == Data([1]) ? image : nil }, frameImage: { _, _ in image })
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
    )
    try #require(status == kCVReturnSuccess)
    return try #require(buffer)
  }
}

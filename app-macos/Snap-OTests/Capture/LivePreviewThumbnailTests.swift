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
        try await suspendUntilCancelled()
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
  func cachedLiveFramePreventsAnOlderScreenshotFromReplacingIt() async throws {
    let thumbnail = LivePreviewThumbnail()
    let pending = TestValue<CheckedContinuation<Data, Never>?>(nil)
    let refresh = Task {
      await thumbnail.refresh(pixelSize: CGSize(width: 80, height: 80)) {
        await withCheckedContinuation { pending.value = $0 }
      }
    }
    try await waitForState { pending.value != nil }
    try thumbnail.cacheLiveFrame(makePixelBuffer(width: 64, height: 32))
    let cached = try #require(thumbnail.image)
    try pending.value?.resume(returning: makePNG())
    await refresh.value
    #expect(thumbnail.image === cached)
  }

  @Test
  func cachingLiveFrameDownsamplesToFillThumbnail() throws {
    let thumbnail = LivePreviewThumbnail()
    thumbnail.pixelSize = CGSize(width: 80, height: 80)
    try thumbnail.cacheLiveFrame(makePixelBuffer(width: 320, height: 160))
    let image = try #require(thumbnail.image)
    #expect(CGSize(width: image.width, height: image.height) == CGSize(width: 160, height: 80))
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

  private func makePNG(size: CGSize = CGSize(width: 320, height: 640)) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}

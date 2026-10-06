import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct LivePreviewThumbnailView: View {
  let attachment: LivePreviewAttachment?
  let isSelected: Bool
  let size: CGSize
  let loadSnapshot: () async throws -> Data
  @State private var snapshot = LivePreviewThumbnail()
  @State private var refresh = LivePreviewThumbnailRefresh()
  @Environment(\.displayScale)
  private var displayScale

  var body: some View {
    let connection = attachment
    let thumbnail = connection?.thumbnail ?? snapshot
    ZStack {
      Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      if let image = thumbnail.image {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .scaledToFill()
      } else {
        VStack(spacing: 4) {
          Image(systemName: "iphone")
          if isSelected ? connection?.hasFailed == true : thumbnail.hasFailed == true {
            Text("Unavailable")
              .font(.caption2)
          } else if !isSelected, thumbnail.isLoading == true {
            ProgressView()
              .controlSize(.mini)
          }
        }
        .foregroundStyle(.secondary)
      }
      if isSelected, connection != nil {
        LivePreviewThumbnailMirror(thumbnail: thumbnail)
          .allowsHitTesting(false)
      }
    }
    .task(id: isSelected) {
      await refresh.run(
        thumbnail: thumbnail,
        isSelected: isSelected,
        pixelSize: CGSize(width: size.width * displayScale, height: size.height * displayScale)
      ) {
        try await loadSnapshot()
      }
    }
  }
}

@MainActor
final class LivePreviewThumbnailRefresh {
  private var didCheckInitialThumbnail = false

  func run(
    thumbnail: LivePreviewThumbnail,
    isSelected: Bool,
    pixelSize: CGSize,
    capture: () async throws -> Data
  ) async {
    thumbnail.pixelSize = pixelSize
    guard !isSelected, !didCheckInitialThumbnail else { return }
    didCheckInitialThumbnail = true
    await thumbnail.refresh(pixelSize: pixelSize, load: capture)
  }
}

private struct LivePreviewThumbnailMirror: NSViewRepresentable {
  let thumbnail: LivePreviewThumbnail

  func makeNSView(context: Context) -> LivePreviewThumbnailDisplayView {
    LivePreviewThumbnailDisplayView()
  }

  func updateNSView(_ view: LivePreviewThumbnailDisplayView, context: Context) {
    view.thumbnail = thumbnail
  }

  static func dismantleNSView(_ view: LivePreviewThumbnailDisplayView, coordinator: Void) {
    view.stop()
  }
}

final class LivePreviewThumbnailDisplayView: NSView {
  weak var thumbnail: LivePreviewThumbnail?
  private let displayLayer = AVSampleBufferDisplayLayer()
  var videoGravity: AVLayerVideoGravity {
    get { displayLayer.videoGravity }
    set { displayLayer.videoGravity = newValue }
  }

  private var displayLink: CADisplayLink?
  private var lastPixelBuffer: CVPixelBuffer?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(displayLayer)
    displayLayer.videoGravity = .resizeAspectFill
    displayLayer.isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopDisplayLink()
    guard window != nil else { return }
    let link = displayLink(target: self, selector: #selector(updateFrame))
    link.add(to: .main, forMode: .common)
    displayLink = link
    updateFrame()
  }

  func stop() {
    stopDisplayLink()
    thumbnail?.cacheLiveFrame()
    thumbnail = nil
    lastPixelBuffer = nil
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc
  private func updateFrame() {
    guard let pixelBuffer = thumbnail?.videoRenderer?.displayedPixelBuffer() else {
      displayLayer.isHidden = true
      lastPixelBuffer = nil
      return
    }
    let renderer = displayLayer.sampleBufferRenderer
    if renderer.requiresFlushToResumeDecoding {
      renderer.flush()
      lastPixelBuffer = nil
    }
    guard pixelBuffer !== lastPixelBuffer else { return }
    guard renderer.isReadyForMoreMediaData else { return }
    guard let sample = Self.sampleBuffer(for: pixelBuffer) else { return }
    // Share the main preview's decoded pixels; the picker never consumes its H.264 stream.
    renderer.enqueue(sample)
    displayLayer.isHidden = false
    lastPixelBuffer = pixelBuffer
  }

  static func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    guard let format = try? CMVideoFormatDescription(imageBuffer: pixelBuffer),
          let sample = try? CMSampleBuffer(
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
          ) else { return nil }
    sample.sampleAttachments[0][.displayImmediately] = true
    return sample
  }
}

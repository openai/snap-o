import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct LivePreviewView: NSViewRepresentable {
  let captureVM: CaptureViewModel

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    if view.layer == nil {
      view.layer = CALayer()
    }
    context.coordinator.setup(in: view, captureVM: captureVM)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.captureVM = captureVM
    context.coordinator.attachToSession()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.teardown()
  }

  @MainActor
  final class Coordinator {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var captureVM: CaptureViewModel?

    init() {
      displayLayer.videoGravity = .resizeAspect
      displayLayer.backgroundColor = NSColor.black.cgColor
    }

    func setup(in view: NSView, captureVM: CaptureViewModel) {
      self.captureVM = captureVM
      displayLayer.frame = view.bounds
      displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      view.layer?.addSublayer(displayLayer)
      attachToSession()
    }

    func enqueue(_ sample: CMSampleBuffer) {
      displayLayer.sampleBufferRenderer.flush()
      displayLayer.sampleBufferRenderer.enqueue(sample)
    }

    func attachToSession() {
      captureVM?.livePreviewSession?.sampleBufferHandler = { [weak self] sample in
        self?.enqueue(sample)
      }
    }

    func teardown() {
      captureVM?.livePreviewSession?.sampleBufferHandler = nil
      displayLayer.sampleBufferRenderer.flush()
      displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    }
  }
}

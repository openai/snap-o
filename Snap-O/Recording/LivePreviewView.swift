import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct LivePreviewView: NSViewRepresentable {
  let controller: CaptureController

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    if view.layer == nil {
      view.layer = CALayer()
    }
    context.coordinator.setup(in: view, controller: controller)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.controller = controller
    context.coordinator.attachToSession()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.teardown()
  }

  @MainActor
  final class Coordinator {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var controller: CaptureController?
    private var endedLivePreviewTrace = false

    init() {
      displayLayer.videoGravity = .resizeAspect
      displayLayer.backgroundColor = NSColor.black.cgColor
    }

    func setup(in view: NSView, controller: CaptureController) {
      self.controller = controller
      displayLayer.frame = view.bounds
      displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      view.layer?.addSublayer(displayLayer)
      attachToSession()
    }

    func enqueue(_ sample: CMSampleBuffer) {
      displayLayer.sampleBufferRenderer.flush()
      displayLayer.sampleBufferRenderer.enqueue(sample)
      if !endedLivePreviewTrace {
        endedLivePreviewTrace = true
        Perf.step(.appFirstSnapshot, "after: Start Live Preview")
        Perf.end(.livePreviewStart, finalLabel: "first frame enqueued")
        Perf.end(.appFirstSnapshot, finalLabel: "first media appeared (live)")
      }
    }

    func attachToSession() {
      controller?.livePreviewSession?.sampleBufferHandler = { [weak self] sample in
        self?.enqueue(sample)
      }
    }

    func teardown() {
      controller?.livePreviewSession?.sampleBufferHandler = nil
      displayLayer.sampleBufferRenderer.flush()
      displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    }
  }
}

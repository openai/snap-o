import SwiftUI

struct CaptureContentView: View {
  let coordinator: CaptureWindowCoordinator
  let deviceStore: DeviceStore

  @State private var windowTitle: String = "Snap-O"

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if coordinator.captureVM.isLivePreviewing {
        LivePreviewView(captureVM: coordinator.captureVM)
          .transition(.opacity)
      } else if let media = coordinator.captureVM.currentMedia {
        MediaDisplayView(media: media, captureVM: coordinator.captureVM)
          .transition(.asymmetric(
            insertion: .scale(scale: 0.8).combined(with: .opacity),
            removal: .scale(scale: 0.8).combined(with: .opacity)
          ))
      } else {
        IdleOverlayView(captureVM: coordinator.captureVM, hasDevices: !deviceStore.devices.isEmpty)
      }
    }
    .animation(.snappy(duration: 0.25), value: coordinator.captureVM.currentMedia != nil)
    .animation(.snappy(duration: 0.25), value: coordinator.captureVM.isLivePreviewing)
    .background(
      WindowSizingController(currentMedia: coordinator.captureVM.displayMedia)
        .frame(width: 0, height: 0)
    )
    .onOpenURL {
      coordinator.handle(url: $0)
    }
    .onAppear {
      coordinator.deviceVM.onDevicesChanged(deviceStore.devices)
    }
    .onChange(of: deviceStore.devices) { _, devices in
      coordinator.deviceVM.onDevicesChanged(devices)
      updateTitle(coordinator.deviceVM.currentDevice)
    }
    .onChange(of: coordinator.deviceVM.selectedDeviceID) { _, newID in
      updateTitle(coordinator.deviceVM.currentDevice)
      if let id = newID {
        Task { await coordinator.captureVM.refreshPreview(for: id) }
      }
    }
    .onChange(of: coordinator.showTouchesDuringCapture) { _, newValue in
      Task { await coordinator.captureVM.applyShowTouchesSetting(newValue) }
    }
    .task {
      updateTitle(coordinator.deviceVM.currentDevice)
      if let id = coordinator.deviceVM.selectedDeviceID {
        await coordinator.captureVM.refreshPreview(for: id)
      }
    }
    .navigationTitle(windowTitle) // works when embedded; for window title see below.
  }

  private func updateTitle(_ device: Device?) {
    windowTitle = device?.readableTitle ?? "Snap-O"
  }
}

final class MediaPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
  private let media: Media

  init(media: Media) { self.media = media }

  func filePromiseProvider(
    _ provider: NSFilePromiseProvider,
    fileNameForType fileType: String
  ) -> String {
    let ts = ISO8601DateFormatter().string(from: .init())
      .replacingOccurrences(of: ":", with: "-")

    switch media.kind {
    case .image: return "\(ts).png"
    case .video: return "\(ts).mp4"
    }
  }

  // Copy the real file to the destination supplied by the system.
  func filePromiseProvider(
    _ provider: NSFilePromiseProvider,
    writePromiseTo dstURL: URL,
    completionHandler: (Error?) -> Void
  ) {
    do {
      try FileManager.default.copyItem(at: media.url, to: dstURL)
      completionHandler(nil)
    } catch {
      completionHandler(error)
    }
  }
}

struct InfiniteRotate: ViewModifier {
  var duration: Double
  var animated: Bool
  @State private var spin = false
  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(spin ? 360 : 0))
      .animation(
        animated ? .linear(duration: duration).repeatForever(autoreverses: false) : .none,
        value: spin
      )
      .onAppear { spin = animated }
      .onChange(of: animated) { _, newValue in
        spin = newValue
      }
  }
}

extension View {
  func infiniteRotate(duration: Double = 10, animated: Bool = true) -> some View {
    modifier(InfiniteRotate(duration: duration, animated: animated))
  }
}

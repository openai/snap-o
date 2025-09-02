import SwiftUI

struct CaptureContentView: View {
  let coordinator: CaptureWindowCoordinator
  let deviceStore: DeviceStore

  @State private var windowTitle: String = "Snap-O"

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let media = coordinator.captureVM.currentMedia {
        MediaDisplayView(media: media, captureVM: coordinator.captureVM)
          .transition(
            media.isLivePreview
              ? AnyTransition.opacity
              : AnyTransition.scale(scale: 0.8).combined(with: .opacity)
          )
      } else {
        IdleOverlayView(captureVM: coordinator.captureVM, hasDevices: !coordinator.devices.available.isEmpty)
      }
    }
    .animation(.snappy(duration: 0.25), value: coordinator.captureVM.currentMedia != nil)
    .background(
      WindowSizingController(currentMedia: coordinator.captureVM.currentMedia)
        .frame(width: 0, height: 0)
    )
    .onOpenURL {
      coordinator.handle(url: $0)
    }
    .onAppear {
      coordinator.onDevicesChanged(deviceStore.devices)
    }
    .onChange(of: deviceStore.devices) { _, devices in
      coordinator.onDevicesChanged(devices)
      updateTitle(coordinator.devices.currentDevice)
    }
    .onChange(of: coordinator.devices.selectedID) { _, newID in
      updateTitle(coordinator.devices.currentDevice)
      if let id = newID {
        Task { await coordinator.captureVM.refreshPreview(for: id) }
      }
    }
    .onChange(of: coordinator.showTouchesDuringCapture) { _, newValue in
      Task { await coordinator.captureVM.applyShowTouchesSetting(newValue) }
    }
    .task {
      updateTitle(coordinator.devices.currentDevice)
      if let id = coordinator.devices.selectedID {
        await coordinator.captureVM.refreshPreview(for: id)
      }
    }
    .navigationTitle(windowTitle) // works when embedded; for window title see below.
  }

  private func updateTitle(_ device: Device?) {
    windowTitle = device?.readableTitle ?? "Snap-O"
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

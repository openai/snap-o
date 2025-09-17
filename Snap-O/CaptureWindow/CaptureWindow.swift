import SwiftUI

struct CaptureWindow: View {
  @StateObject private var controller = CaptureWindowController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let transition = transition(for: controller.transitionDirection)

      if controller.isDeviceListInitialized || controller.currentCapture != nil {
        CaptureMediaView(controller: controller)
          .id(controller.currentCaptureViewID)
          .transition(transition)
      } else {
        WaitingForDeviceView(isDeviceListInitialized: controller.isDeviceListInitialized)
          .transition(transition)
      }
    }
    .task { await controller.start() }
    .onDisappear { controller.tearDown() }
    .focusedSceneObject(controller)
    .navigationTitle(controller.currentCapture?.device.displayTitle ?? "Snap-O")
    .toolbar {
      CaptureToolbar(controller: controller)
    }
    .animation(.snappy(duration: 0.25), value: controller.currentCaptureViewID)
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    return switch direction {
    case .previous: xTransition(insertion: .leading, removal: .trailing)
    case .next: xTransition(insertion: .trailing, removal: .leading)
    case .neutral: .opacity
    }
  }

  private func xTransition(insertion: Edge, removal: Edge) -> AnyTransition {
    return .asymmetric(
      insertion: .move(edge: insertion).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }
}

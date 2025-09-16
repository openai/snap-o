import SwiftUI

struct CaptureWindow: View {
  @StateObject private var controller = CaptureWindowController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let transition = transition(for: controller.transitionDirection)

      if controller.isDeviceListInitialized || controller.currentCapture != nil {
        CaptureMediaView(controller: controller)
          .id(controller.currentCapture?.id)
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
    .animation(.snappy(duration: 0.25), value: controller.currentCapture?.id)
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    switch direction {
    case .previous: xTransition(offset: 60)
    case .next: xTransition(offset: -60)
    case .neutral: .opacity
    }
  }

  private func xTransition(offset: CGFloat) -> AnyTransition {
    let move = AnyTransition.offset(x: offset).combined(with: .opacity)
    return .asymmetric(
      insertion: move,
      removal: .offset(x: -offset).combined(with: .opacity)
    )
  }
}

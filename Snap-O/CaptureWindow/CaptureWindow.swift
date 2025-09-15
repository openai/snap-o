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
    .toolbar {
      TitleCapturePickerToolbar(controller: controller)
      CaptureToolbar(controller: controller)
    }
    .animation(.snappy(duration: 0.25), value: controller.currentCapture?.id)
    .background(
      WindowTitleVisibilityController()
        .frame(width: 0, height: 0)
    )
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    switch direction {
    case .up: yTransition(offset: 60)
    case .down: yTransition(offset: -60)
    case .neutral: .opacity
    }
  }

  private func yTransition(offset: CGFloat) -> AnyTransition {
    let move = AnyTransition.offset(y: offset).combined(with: .opacity)
    return .asymmetric(
      insertion: move,
      removal: .offset(y: -offset).combined(with: .opacity)
    )
  }
}

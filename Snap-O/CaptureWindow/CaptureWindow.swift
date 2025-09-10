import SwiftUI

struct CaptureWindow: View {
  @StateObject private var deviceSelectionController = CaptureDeviceSelectionController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let transition = transition(for: deviceSelectionController.transitionDirection)

      if let deviceID = deviceSelectionController.devices.selectedID {
        CaptureDeviceView(
          deviceID: deviceID,
          deviceSelectionController: deviceSelectionController
        )
        .id(deviceID)
        .transition(transition)
      } else {
        WaitingForDeviceView(isDeviceListInitialized: deviceSelectionController.isDeviceListInitialized)
          .transition(transition)
      }
    }
    .task { await deviceSelectionController.start() }
    .focusedSceneObject(deviceSelectionController)
    .toolbar {
      TitleDevicePickerToolbar(deviceSelection: deviceSelectionController)
    }
    .animation(.snappy(duration: 0.25), value: deviceSelectionController.devices.selectedID)
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

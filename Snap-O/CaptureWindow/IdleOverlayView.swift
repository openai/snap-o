import SwiftUI

struct IdleOverlayView: View {
  @ObservedObject var controller: CaptureWindowController

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: controller.isProcessing)

      if controller.isRecording {
        Button {
          Task { await controller.stopRecording() }
        } label: {
          HStack(spacing: 8) {
            Text("Stop Recording")
            Text("⎋")
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.7))
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(Color.gray.opacity(0.3))
          )
          .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .transition(.opacity)
      } else if !controller.hasDevices, controller.isDeviceListInitialized {
        Text("Waiting for device…")
          .foregroundStyle(.gray)
          .transition(.opacity)
      }

      if let err = controller.lastError {
        Text(err)
          .font(.footnote)
          .foregroundStyle(.red)
          .transition(.opacity)
      }
    }
    .animation(.snappy(duration: 0.25), value: animationState)
  }

  private var animationState: AnimationState {
    AnimationState(
      isRecording: controller.isRecording,
      hasDevices: controller.hasDevices,
      isDeviceListInitialized: controller.isDeviceListInitialized,
      hasError: controller.lastError != nil
    )
  }
}

private struct AnimationState: Equatable {
  var isRecording: Bool
  var hasDevices: Bool
  var isDeviceListInitialized: Bool
  var hasError: Bool
}

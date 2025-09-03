import SwiftUI

struct IdleOverlayView: View {
  let controller: CaptureController
  let hasDevices: Bool
  let isDeviceListInitialized: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: true)

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
      } else if controller.currentMedia?.isLivePreview == true {
        Button {
          Task { await controller.stopLivePreview(withRefresh: true) }
        } label: {
          HStack {
            Text("Stop Live Preview")
            Text("⎋").tint(.secondary)
          }
        }
        .keyboardShortcut(.cancelAction)
        .transition(.opacity)
      } else if !hasDevices && isDeviceListInitialized {
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
    .animation(.snappy(duration: 0.25), value: controller.isRecording)
    .animation(
      .snappy(duration: 0.25),
      value: controller.currentMedia?.isLivePreview == true
    )
    .animation(.snappy(duration: 0.25), value: controller.lastError != nil)
    .animation(.snappy(duration: 0.25), value: hasDevices)
    .animation(.snappy(duration: 0.25), value: isDeviceListInitialized)
  }
}

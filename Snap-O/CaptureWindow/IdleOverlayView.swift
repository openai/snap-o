import SwiftUI

struct IdleOverlayView: View {
  let captureVM: CaptureViewModel
  let hasDevices: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: hasDevices)

      if captureVM.isRecording {
        Button {
          Task { await captureVM.stopRecording() }
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
      } else if captureVM.currentMedia?.isLivePreview == true {
        Button {
          Task { await captureVM.stopLivePreview(withRefresh: true) }
        } label: {
          HStack {
            Text("Stop Live Preview")
            Text("⎋").tint(.secondary)
          }
        }
        .keyboardShortcut(.cancelAction)
        .transition(.opacity)
      } else if !hasDevices {
        Text("No device found")
          .foregroundStyle(.gray)
          .transition(.opacity)
      }

      if let err = captureVM.lastError {
        Text(err)
          .font(.footnote)
          .foregroundStyle(.red)
          .transition(.opacity)
      }
    }
    .animation(.snappy(duration: 0.25), value: captureVM.isRecording)
    .animation(
      .snappy(duration: 0.25),
      value: captureVM.currentMedia?.isLivePreview == true
    )
    .animation(.snappy(duration: 0.25), value: captureVM.lastError != nil)
    .animation(.snappy(duration: 0.25), value: hasDevices)
  }
}

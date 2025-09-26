import SwiftUI

struct IdleOverlayView: View {
  let hasDevices: Bool
  let isDeviceListInitialized: Bool
  let isProcessing: Bool
  let isRecording: Bool
  let stopRecording: () -> Void
  let lastError: String?

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: isProcessing)

      if isRecording, !isProcessing {
        Button {
          stopRecording()
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
      } else if isRecording {
        ProgressView()
          .progressViewStyle(.circular)
          .tint(.white)
          .controlSize(.large)
      } else if !hasDevices, isDeviceListInitialized {
        Text("Waiting for device…")
          .foregroundStyle(.gray)
      }

      if let err = lastError {
        Text(err)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
  }
}

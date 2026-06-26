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
        .renderingMode(.template)
        .resizable()
        .foregroundStyle(.secondary)
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: isProcessing || isRecording)

      if isRecording, !isProcessing {
        Button {
          stopRecording()
        } label: {
          HStack(spacing: 8) {
            Text("Stop Recording")
            Text("⎋")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .keyboardShortcut(.cancelAction)
      } else if isRecording {
        ProgressView()
          .progressViewStyle(.circular)
          .tint(.primary)
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

import SwiftUI

extension EnvironmentValues {
  @Entry var livePreviewLoadingMessage: @MainActor (String) -> String = { _ in "Connecting" }
}

struct WaitingForDeviceView: View {
  let isDeviceListInitialized: Bool
  var deviceMessage = "Waiting for device"
  var cancel: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .renderingMode(.template)
        .resizable()
        .foregroundStyle(.secondary)
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: true)

      if !isDeviceListInitialized {
        Text("Waiting for ADB server")
          .foregroundStyle(.secondary)
        Text("Run `adb start-server` in Terminal. Snap-O reconnects automatically.")
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .transition(.opacity)
      } else {
        Text(deviceMessage)
          .foregroundStyle(.gray)
          .transition(.opacity)
      }
      if let cancel {
        Button("Cancel", action: cancel)
      }
    }
    .multilineTextAlignment(.center)
    .padding(24)
  }
}

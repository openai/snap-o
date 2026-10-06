import SwiftUI

extension EnvironmentValues {
  @Entry var livePreviewLoadingMessage: @MainActor (String) -> String = { _ in "Connecting" }
}

struct WaitingForDeviceView: View {
  var deviceMessage = "Waiting for device"
  var serverState: ADBServerState = .online
  var retryADBServer: () -> Void = {}
  var cancel: (() -> Void)?

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .renderingMode(.template)
        .resizable()
        .foregroundStyle(.secondary)
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: true)

      switch serverState {
      case .starting:
        Text("Starting ADB server")
          .foregroundStyle(.secondary)
      case .connecting:
        Text("Connecting to ADB server")
          .foregroundStyle(.secondary)
      case .unavailable(let message):
        Text("ADB server unavailable")
          .foregroundStyle(.secondary)
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .frame(maxWidth: 420)
        Button("Start ADB server", action: retryADBServer)
      case .online:
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

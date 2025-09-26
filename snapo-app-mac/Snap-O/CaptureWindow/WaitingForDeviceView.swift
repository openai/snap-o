import SwiftUI

struct WaitingForDeviceView: View {
  let isDeviceListInitialized: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: true)

      if !isDeviceListInitialized {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading devices…")
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      } else {
        Text("Waiting for device…")
          .foregroundStyle(.gray)
          .transition(.opacity)
      }
    }
  }
}

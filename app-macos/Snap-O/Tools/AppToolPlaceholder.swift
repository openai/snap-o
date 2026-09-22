import SwiftUI

struct AppToolPlaceholder: View {
  let presentation: AppToolPresentation
  let retry: () -> Void

  var body: some View {
    if let message = presentation.message {
      VStack(spacing: 12) {
        Text(message).foregroundStyle(.secondary)
        if presentation == .discoveryFailed {
          Button("Retry", action: retry)
        }
      }
    }
  }
}

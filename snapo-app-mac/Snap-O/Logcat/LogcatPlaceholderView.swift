import SwiftUI

struct LogcatPlaceholderView: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 44))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

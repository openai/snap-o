import SwiftUI

struct ScreenshotFailureBanner: View {
  let failures: [CaptureFailure]
  let successfulCaptureCount: Int
  let onDismiss: () -> Void

  private var title: String {
    let total = successfulCaptureCount + failures.count
    if total == 1 { return "Screenshot failed" }
    return "\(failures.count) of \(total) screenshots failed"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 14))
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))

        ForEach(failures, id: \.device.id) { failure in
          Text(failure.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)

      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Dismiss")
    }
    .padding(12)
    .frame(maxWidth: 460, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
  }
}

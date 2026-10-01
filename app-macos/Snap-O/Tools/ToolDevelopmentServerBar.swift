import SwiftUI

struct ToolDevelopmentServerBar: View {
  let url: URL
  let usePackagedFrontend: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Label("Development server", systemImage: "hammer")
        .fontWeight(.medium)
        .fixedSize()
      Text(url.absoluteString)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(url.absoluteString)
      Spacer(minLength: 0)
      Button("Use Default", action: usePackagedFrontend)
        .controlSize(.small)
        .fixedSize()
        .help("Use the inspector bundled with the Android app.")
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}

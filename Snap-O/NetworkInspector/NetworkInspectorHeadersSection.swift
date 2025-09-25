import SwiftUI

struct NetworkInspectorHeadersSection: View {
  let title: String
  let headers: [NetworkInspectorRequestViewModel.Header]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      if headers.isEmpty {
        Text("None")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        SelectableHeaderList(headers: headers)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

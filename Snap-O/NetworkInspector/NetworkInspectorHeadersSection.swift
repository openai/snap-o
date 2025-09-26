import SwiftUI

struct NetworkInspectorHeadersSection: View {
  let title: String
  let headers: [NetworkInspectorRequestViewModel.Header]
  @State private var isExpanded: Bool

  init(title: String, headers: [NetworkInspectorRequestViewModel.Header]) {
    self.title = title
    self.headers = headers
    _isExpanded = State(initialValue: true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .rotationEffect(isExpanded ? .degrees(90) : .zero)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        Group {
          if headers.isEmpty {
            Text("None")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            SelectableHeaderList(headers: headers)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

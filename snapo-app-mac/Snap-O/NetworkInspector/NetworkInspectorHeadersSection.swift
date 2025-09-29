import SwiftUI

struct NetworkInspectorHeadersSection: View {
  let title: String
  let headers: [NetworkInspectorRequestViewModel.Header]
  private let externalBinding: Binding<Bool>?
  @State private var internalExpanded: Bool

  init(title: String, headers: [NetworkInspectorRequestViewModel.Header], isExpanded: Binding<Bool>? = nil) {
    self.title = title
    self.headers = headers
    externalBinding = isExpanded
    _internalExpanded = State(initialValue: isExpanded?.wrappedValue ?? true)
  }

  var body: some View {
    let binding = externalBinding ?? $internalExpanded
    VStack(alignment: .leading, spacing: 6) {
      Button {
        binding.wrappedValue.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .rotationEffect(binding.wrappedValue ? .degrees(90) : .zero)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if binding.wrappedValue {
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

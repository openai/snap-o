import SwiftUI

struct NetworkInspectorRequestDetailView: View {
  let request: NetworkInspectorRequestViewModel
  let onClose: () -> Void

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        NetworkInspectorHeadersSection(title: "Request Headers", headers: request.requestHeaders)
        if let requestBody = request.requestBody {
          NetworkInspectorBodySection(title: "Request Body", payload: requestBody)
        }
        NetworkInspectorHeadersSection(title: "Response Headers", headers: request.responseHeaders)

        if let responseBody = request.responseBody {
          NetworkInspectorBodySection(title: "Response Body", payload: responseBody)
        }
      }
      .padding(24)
    }
  }

  private var headerSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(request.method)
            .font(.title3.weight(.semibold))
            .textSelection(.enabled)
          Text(request.url)
            .font(.body)
            .textSelection(.enabled)
        }
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Close request detail")
      }

      HStack(spacing: 12) {
        statusBadge
        Text(request.timingSummary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      if case .failure(let message) = request.status, let message, !message.isEmpty {
        Text("Error: \(message)")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
  }

  private var statusBadge: some View {
    let label: String
    let color: Color

    switch request.status {
    case .pending:
      label = "Pending"
      color = .secondary
    case .success(let code):
      label = "Success (\(code))"
      color = .green
    case .failure:
      label = "Failed"
      color = .red
    }

    return Text(label)
      .font(.caption)
      .foregroundStyle(color)
  }
}

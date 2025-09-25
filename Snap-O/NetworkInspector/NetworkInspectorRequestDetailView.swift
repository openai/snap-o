import SwiftUI

struct NetworkInspectorRequestDetailView: View {
  let request: NetworkInspectorRequestViewModel

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        NetworkInspectorHeadersSection(title: "Request Headers", headers: request.requestHeaders)
        NetworkInspectorHeadersSection(title: "Response Headers", headers: request.responseHeaders)

        if let responseBody = request.responseBody {
          NetworkInspectorBodySection(title: "Response Body", responseBody: responseBody)
        }
      }
      .padding(24)
    }
  }

  private var headerSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(request.method)
          .font(.title3.weight(.semibold))
          .textSelection(.enabled)
        Text(request.url)
          .font(.body)
          .textSelection(.enabled)
      }

      HStack(spacing: 12) {
        statusBadge
        Text(request.requestIdentifier)
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

      Text(request.serverSummary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Text(request.timingSummary)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
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
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

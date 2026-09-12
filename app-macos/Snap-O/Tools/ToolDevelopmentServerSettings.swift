import SwiftUI

struct ToolDevelopmentServerSettings: View {
  let model: ToolHostModel
  @Environment(\.dismiss)
  private var dismiss
  @State private var address: String

  init(model: ToolHostModel) {
    self.model = model
    _address = State(initialValue: model.developmentURL?.absoluteString ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Development Server").font(.headline)
      TextField("URL", text: $address)
        .textFieldStyle(.roundedBorder)
      Text("Use a trusted local server. Its code can access this tool’s Android endpoint and request native actions. "
        + "The override is saved for this app and tool.")
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Use Server") {
          guard let url = ToolWebPolicy.developmentURL(address) else { return }
          model.useDevelopmentServer(url)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(ToolWebPolicy.developmentURL(address) == nil)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}

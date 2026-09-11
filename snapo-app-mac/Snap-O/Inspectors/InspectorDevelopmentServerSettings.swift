import SwiftUI

struct InspectorDevelopmentServerSettings: View {
  let model: InspectorHostModel
  @Environment(\.dismiss)
  private var dismiss
  @State private var address: String

  init(model: InspectorHostModel) {
    self.model = model
    _address = State(initialValue: model.developmentURL?.absoluteString ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Development Server").font(.headline)
      TextField("URL", text: $address)
        .textFieldStyle(.roundedBorder)
      Text("Use a trusted local server. Its code can access this inspector’s Android endpoint and request native actions. "
        + "The override is saved for this app and inspector.")
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Use Server") {
          guard let url = InspectorWebPolicy.developmentURL(address) else { return }
          model.useDevelopmentServer(url)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(InspectorWebPolicy.developmentURL(address) == nil)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}

import SwiftUI

struct CaptureSaveSheet: View {
  let save: @MainActor (String) async throws -> Void
  @Environment(\.dismiss)
  private var dismiss
  @State private var name = ""
  @State private var isSaving = false
  @State private var errorMessage: String?
  @FocusState private var isNameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Save to Capture History").font(.headline)
      TextField("Name (optional)", text: $name)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Capture name")
        .focused($isNameFocused)
        .onSubmit(submit)
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if isSaving { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save", action: submit).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 320)
    .disabled(isSaving)
    .interactiveDismissDisabled(isSaving)
    .onAppear { isNameFocused = true }
  }

  private func submit() {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    Task {
      do {
        try await save(name)
      } catch {
        errorMessage = error.localizedDescription
        isSaving = false
      }
    }
  }
}

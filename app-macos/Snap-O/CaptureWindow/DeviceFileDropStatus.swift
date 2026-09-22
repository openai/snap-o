import SwiftUI

struct DeviceFileDropStatus: View {
  @Bindable var model: DeviceFileDrop
  @State private var showsDetails = false

  private var message: String {
    if model.isBusy { return model.status ?? "Preparing…" }
    if let failure = model.failures.last { return failure.message }
    return model.status ?? ""
  }

  private var details: [String] {
    model.failures.compactMap(\.details)
  }

  var body: some View {
    HStack(spacing: 10) {
      if model.isBusy {
        ProgressView()
          .controlSize(.small)
          .frame(width: 14, height: 14)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(message)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if model.isBusy, let progress = model.progress {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
        }
      }
      if model.isBusy {
        Button("Cancel", action: model.cancel)
          .fixedSize()
      } else {
        if !model.failures.isEmpty, !details.isEmpty || model.status != nil {
          Button("Details") { showsDetails = true }
            .fixedSize()
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
              ScrollView {
                Text(([model.status].compactMap(\.self) + details).joined(separator: "\n\n"))
                  .font(.callout)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(16)
              }
              .frame(width: 340, height: 180)
            }
        }
        Button(action: model.dismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Dismiss")
      }
    }
    .font(.callout)
    .controlSize(.small)
    .buttonStyle(.borderless)
    .padding(.vertical, 10)
    .padding(.leading, 14)
    .padding(.trailing, 10)
    .frame(maxWidth: 420)
    .fixedSize(horizontal: false, vertical: true)
    // Use a stable surface instead of glass's adaptive contrast over live video.
    .background(
      Color(nsColor: .windowBackgroundColor).opacity(0.92),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .padding(12)
    .task(id: model.status) {
      guard !model.isBusy, model.failures.isEmpty, let status = model.status else { return }
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      if !model.isBusy, model.status == status, model.failures.isEmpty { model.dismiss() }
    }
  }
}

import SwiftUI

struct CaptureHistorySettings: View {
  let history: CaptureHistory
  @Environment(\.dismiss)
  private var dismiss
  @State private var policy = CaptureHistoryRetention()
  @State private var removalCandidates: [CaptureHistoryEntry] = []
  @State private var confirmsPolicy = false
  @State private var confirmsClear = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("History Storage").font(.title2)
      VStack(alignment: .leading, spacing: 8) {
        Text("\(ByteCountFormatter.string(fromByteCount: history.byteCount, countStyle: .file)) used")
        ProgressView(
          value: min(Double(history.byteCount), Double(history.retention.limitBytes)),
          total: Double(history.retention.limitBytes)
        )
        if history.byteCount > history.retention.limitBytes {
          Text("Captures in use and new oversized captures can temporarily exceed the limit.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Form {
        Picker("Keep captures for", selection: $policy.days) {
          ForEach(CaptureHistoryRetention.dayChoices, id: \.self) { days in
            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
          }
        }
        Picker("Storage limit", selection: $policy.limitBytes) {
          ForEach(CaptureHistoryRetention.sizeChoices, id: \.self) { bytes in
            Text("\(bytes / 1_000_000_000) GB").tag(bytes)
          }
        }
      }
      Text("Oldest captures are removed when either limit is reached. All devices in a capture are removed together.")
        .font(.callout).foregroundStyle(.secondary)
      Text("Captures in use are protected from automatic cleanup. "
        + "A new capture larger than the limit is kept for 24 hours. Use Save As to keep a permanent copy.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Clear History…", role: .destructive) { confirmsClear = true }
          .disabled(history.entries.isEmpty)
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Apply") {
          Task {
            removalCandidates = await history.repository.cleanupCandidates(using: policy)
            if removalCandidates.isEmpty { await apply() } else { confirmsPolicy = true }
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
    .onAppear { policy = history.retention }
    .alert("Apply storage settings?", isPresented: $confirmsPolicy) {
      Button("Apply and Remove", role: .destructive) { Task { await apply() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("\(removalCandidates.count) older captures will be removed.")
    }
    .alert("Clear capture history?", isPresented: $confirmsClear) {
      Button("Clear History", role: .destructive) {
        Task {
          await history.repository.delete(Set(history.entries.map(\.id)))
          dismiss()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All completed captures will be permanently deleted, including captures in use.")
    }
  }

  private func apply() async {
    await history.repository.setRetention(policy)
    dismiss()
  }
}
